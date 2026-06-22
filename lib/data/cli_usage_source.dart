import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/usage_error.dart';
import '../models/usage_snapshot.dart';
import '../models/usage_window.dart';

/// Result of a CLI usage probe: a snapshot, or a classified [UsageError].
class CliUsageResult {
  final UsageSnapshot? snapshot;
  final UsageError? error;

  const CliUsageResult.ok(this.snapshot) : error = null;
  const CliUsageResult.fail(this.error) : snapshot = null;

  bool get isOk => snapshot != null;
}

/// Fetches usage by spawning `claude -p "/usage" --output-format json` —
/// the app's only usage source.
///
/// Claude Code reads its own credentials in-process, so this path can never
/// trigger the macOS Keychain password prompt — even on machines where
/// Claude Code recreates its keychain item and wipes the ACL (the root cause
/// of the repeated prompts some users saw; see CodexBar issue #340 for the
/// same failure mode). The `/usage` slash command is handled locally by the
/// CLI (`num_turns: 0`, `total_cost_usd: 0`), so probes are free, hit no
/// model, and take ~0.5s.
///
/// There is deliberately no Keychain/API fallback: a silent fallback would
/// mask a CLI format change (and quietly bring the password prompts back),
/// so failures are classified instead — see [_classifyFailure].
class CliUsageSource {
  CliUsageSource({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Resolved path of the `claude` binary. Null = not searched yet, empty =
  /// searched and absent (so the candidates are only walked once per run).
  String? _binary;

  /// Plan label from `claude auth status` — changes essentially never, so
  /// one probe per app run is enough.
  String? _plan;

  /// `/usage` answers in ~0.5s normally, but the CLI can stall behind a
  /// token refresh against a slow Cloudflare-fronted endpoint.
  static const _timeout = Duration(seconds: 20);

  /// Where the probe runs. A fixed, dedicated cwd means the session files
  /// Claude Code writes all land in one predictable project bucket that
  /// only ClaudeBar's probes ever touch. Deliberately dot/space-free so the
  /// `~/.claude/projects` directory-name encoding stays unsurprising.
  static const _probeDir = '/tmp/claudebar-usage-probe';

  /// Returns a fresh snapshot, or a [UsageError] describing why the probe
  /// failed — classified so the UI can say the right thing for each cause.
  Future<CliUsageResult> fetch() async {
    // flutter_tester would happily spawn the real CLI on the dev machine —
    // keep widget tests hermetic. noCredentials renders the same harmless
    // "Sign in" state tests saw before.
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return const CliUsageResult.fail(UsageError.noCredentials);
    }

    if (await _resolveBinary() == null) {
      return const CliUsageResult.fail(UsageError.cliMissing);
    }

    final out = await _run(['-p', '/usage', '--output-format', 'json']);
    String? text;
    // True once the CLI hands back a successful envelope with a string result —
    // i.e. it ran fine and answered. Distinguishes "answered but no usage lines"
    // (a transient empty reply → noData) from "the CLI itself failed" (offline /
    // crashed / format changed), which _classifyFailure handles separately.
    var gotReply = false;
    if (out != null) {
      final envelope = decodeEnvelope(out);
      if (envelope != null && envelope['is_error'] != true) {
        final result = envelope['result'];
        if (result is String) {
          text = result;
          gotReply = true;
          // Each print-mode run records a session under ~/.claude/projects;
          // at one probe per refresh that would pile up ~300 stub files a
          // day. Delete the one we just created — identified by its exact
          // session id, so no other session can ever be touched.
          final sessionId = envelope['session_id'];
          if (sessionId is String) unawaited(_deleteProbeSession(sessionId));
        }
      }
    }

    if (text != null) {
      final snapshot =
          parseUsageText(text, plan: await _planLabel(), now: _now());
      if (snapshot != null) return CliUsageResult.ok(snapshot);
      debugPrint('[ClaudeBar] /usage output did not match the expected shape');
    }
    return CliUsageResult.fail(await _classifyFailure(gotReply: gotReply));
  }

  /// Runs only when a probe failed (rare): works out *why*, so each cause
  /// gets the right message instead of a generic error. [gotReply] means the
  /// CLI answered with a string result that simply lacked the usage lines.
  Future<UsageError> _classifyFailure({required bool gotReply}) async {
    // Signed out? `auth status` is answered locally, so it works offline.
    final out = await _run(['auth', 'status', '--json']);
    if (out != null && decodeEnvelope(out)?['loggedIn'] == false) {
      return UsageError.noCredentials;
    }
    // The CLI answered, we're signed in — it just didn't carry the numbers
    // (the print-mode /usage probe often returns its preamble before the
    // fetch lands). That's the common transient case, distinct from a genuine
    // format change: keep-last-known and retry, don't cry "update the app".
    if (gotReply) return UsageError.noData;
    // Offline? If the API host doesn't resolve, the CLI failed for the same
    // reason — keep-last-known is the right UX, not "update the app".
    try {
      await InternetAddress.lookup('api.anthropic.com')
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return UsageError.network;
    }
    // Online, signed in, CLI present, but produced no parsable reply at all —
    // the output shape must have changed.
    return UsageError.parseFailed;
  }

  // ---- parsing (pure, unit-tested) ----

  /// One usage line, e.g. `Current session: 35% used · resets Jun 13 at
  /// 1:49am (Asia/Bangkok)` — the resets clause and the per-model lines are
  /// optional.
  static final _lineRe = RegExp(
    r'^Current (session|week \(([^)]+)\)):\s*(\d+(?:\.\d+)?)% used'
    r'(?:\s*·\s*resets\s+(.+?))?\s*$',
    multiLine: true,
  );

  /// Parses the human text inside the JSON envelope's `result` field into a
  /// snapshot, or null when the expected session/weekly lines are absent
  /// (logged out, or the CLI changed its wording).
  @visibleForTesting
  static UsageSnapshot? parseUsageText(
    String text, {
    required String plan,
    required DateTime now,
  }) {
    UsageWindow? session, weekly, opus, sonnet;
    for (final m in _lineRe.allMatches(text)) {
      final qualifier = m.group(2)?.toLowerCase();
      final percent =
          (double.tryParse(m.group(3)!) ?? 0).clamp(0, 100).toDouble();
      final resetsAt = _parseReset(m.group(4), now);

      UsageWindow window(String label) =>
          UsageWindow(percent: percent, resetsAt: resetsAt, label: label);

      // Labels mirror usage_api.dart so the UI renders identically
      // regardless of which source produced the snapshot.
      if (m.group(1) == 'session') {
        session = window('Session · 5h');
      } else if (qualifier == null) {
        continue;
      } else if (qualifier.contains('all')) {
        weekly = window('Weekly · 7d');
      } else if (qualifier.contains('opus')) {
        opus = window('Opus · weekly');
      } else if (qualifier.contains('sonnet')) {
        sonnet = window('Sonnet · weekly');
      }
    }
    if (session == null || weekly == null) return null;
    return UsageSnapshot(
      session: session,
      weekly: weekly,
      opus: opus,
      sonnet: sonnet,
      plan: plan,
      fetchedAt: now,
    );
  }

  static final _resetRe = RegExp(
    r'^([A-Za-z]{3,9})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)',
    caseSensitive: false,
  );

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Parses `Jun 13 at 1:49am (Asia/Bangkok)` into a local DateTime. The CLI
  /// prints the machine's own timezone, so constructing a local DateTime is
  /// correct; the parenthesized zone name is ignored. Returns null on any
  /// unrecognized wording — the UI tolerates a missing reset time.
  static DateTime? _parseReset(String? phrase, DateTime now) {
    if (phrase == null) return null;
    final m = _resetRe.firstMatch(phrase.trim());
    if (m == null) return null;
    final month = _months[m.group(1)!.toLowerCase().substring(0, 3)];
    if (month == null) return null;
    final day = int.parse(m.group(2)!);
    var hour = int.parse(m.group(3)!) % 12;
    if (m.group(5)!.toLowerCase() == 'pm') hour += 12;
    final minute = int.tryParse(m.group(4) ?? '') ?? 0;

    // The phrase carries no year. Resets always land within ~7 days of now,
    // so a candidate well in the past belongs to next year (Dec→Jan
    // boundary), and one absurdly far ahead to last year (Jan→Dec, stale).
    var candidate = DateTime(now.year, month, day, hour, minute);
    if (candidate.isBefore(now.subtract(const Duration(days: 1)))) {
      candidate = DateTime(now.year + 1, month, day, hour, minute);
    } else if (candidate.isAfter(now.add(const Duration(days: 300)))) {
      candidate = DateTime(now.year - 1, month, day, hour, minute);
    }
    return candidate;
  }

  /// Decodes the CLI's JSON output, skipping any preamble noise before the
  /// first `{` (shell profiles and Node warnings occasionally print first).
  @visibleForTesting
  static Map<String, dynamic>? decodeEnvelope(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    try {
      final decoded = jsonDecode(raw.substring(start).trim());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // ---- process plumbing ----

  Future<String?> _run(List<String> args) async {
    final bin = await _resolveBinary();
    if (bin == null) return null;
    try {
      final proc = await Process.start(
        bin,
        args,
        workingDirectory: _ensureProbeDir(),
        // npm-installed `claude` is a Node script — make sure `node` resolves
        // even though GUI apps launch with a minimal PATH.
        environment: {...Platform.environment, 'PATH': _augmentedPath()},
      );
      final outF = proc.stdout.transform(utf8.decoder).join();
      final errF = proc.stderr.transform(utf8.decoder).join();
      final exit = await proc.exitCode.timeout(_timeout, onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
      final out = await outF;
      if (exit != 0) {
        debugPrint(
          '[ClaudeBar] claude ${args.join(' ')} exited $exit: '
          '${(await errF).trim()}',
        );
        return null;
      }
      return out;
    } catch (e) {
      debugPrint('[ClaudeBar] failed to spawn claude: $e');
      return null;
    }
  }

  /// Finds the `claude` binary once per run: well-known install locations
  /// first, then a login shell as the last resort (GUI apps don't inherit
  /// the user's PATH).
  Future<String?> _resolveBinary() async {
    final cached = _binary;
    if (cached != null) return cached.isEmpty ? null : cached;

    final home = Platform.environment['HOME'];
    final candidates = [
      if (home != null) '$home/.local/bin/claude',
      '/opt/homebrew/bin/claude',
      '/usr/local/bin/claude',
    ];
    for (final c in candidates) {
      if (File(c).existsSync() && _isExecutable(c)) return _binary = c;
    }
    try {
      final r = await Process.run('/bin/zsh', ['-lc', 'command -v claude'])
          .timeout(const Duration(seconds: 5));
      // Profiles can echo before the path — keep only the last line.
      final lines = (r.stdout as String)
          .trim()
          .split('\n')
          .where((l) => l.trim().isNotEmpty);
      final path = lines.isEmpty ? '' : lines.last.trim();
      if (r.exitCode == 0 &&
          path.isNotEmpty &&
          File(path).existsSync() &&
          _isExecutable(path)) {
        return _binary = path;
      }
    } catch (_) {}
    _binary = '';
    return null;
  }

  /// True when [path] resolves to a file with an execute bit set. A broken
  /// `claude` install — e.g. an npm symlink left pointing at a non-executable
  /// stub (`...claude.exe`, mode `rw-r--r--`) when its postinstall never
  /// fetched the real binary — exists on disk but can only ever yield EACCES
  /// "Permission denied" when spawned. Skipping it lets resolution fall through
  /// to a working install, and when there is none we report "CLI not found"
  /// (accurate) instead of misclassifying the dead probe as a format change
  /// ("Update ClaudeBar?"). statSync follows the symlink, so this checks the
  /// real target's permissions.
  bool _isExecutable(String path) {
    try {
      return (File(path).statSync().mode & 0x49) != 0; // any of u/g/o +x (0o111)
    } catch (_) {
      return false;
    }
  }

  String _augmentedPath() {
    final home = Platform.environment['HOME'];
    return [
      if (home != null) '$home/.local/bin',
      '/opt/homebrew/bin',
      '/usr/local/bin',
      Platform.environment['PATH'] ?? '/usr/bin:/bin',
    ].join(':');
  }

  String _ensureProbeDir() {
    try {
      Directory(_probeDir).createSync(recursive: true);
      return _probeDir;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  /// Plan badge text via `claude auth status --json` (subscriptionType),
  /// e.g. "max" → "Max". Cached after the first success.
  Future<String> _planLabel() async {
    final cached = _plan;
    if (cached != null) return cached;
    final out = await _run(['auth', 'status', '--json']);
    final sub = out == null ? null : decodeEnvelope(out)?['subscriptionType'];
    if (sub is! String || sub.isEmpty) return 'Claude';
    return _plan = sub[0].toUpperCase() + sub.substring(1).toLowerCase();
  }

  static final _uuidRe = RegExp(r'^[0-9a-fA-F-]{36}$');

  /// Removes the session stub the probe just wrote under
  /// `~/.claude/projects`. Scoped hard: only a file named exactly
  /// `<session_id>.jsonl` (validated as a UUID) is ever deleted.
  Future<void> _deleteProbeSession(String sessionId) async {
    if (!_uuidRe.hasMatch(sessionId)) return;
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final projects = Directory('$home/.claude/projects');
      if (!projects.existsSync()) return;
      for (final entry in projects.listSync()) {
        if (entry is! Directory) continue;
        final file = File('${entry.path}/$sessionId.jsonl');
        if (file.existsSync()) {
          await file.delete();
          return;
        }
      }
    } catch (e) {
      debugPrint('[ClaudeBar] probe session cleanup failed: $e');
    }
  }
}
