import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/diag.dart';
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

/// Everything one finished `claude` run handed back. Kept whole — not just
/// stdout-on-success — because some answers arrive with a non-zero exit:
/// `claude auth status` exits 1 precisely when Claude Code is signed out, and
/// still prints the JSON that says so.
class CliOutput {
  final int exitCode;
  final String stdout;
  final String stderr;

  const CliOutput(this.exitCode, this.stdout, [this.stderr = '']);

  bool get ok => exitCode == 0;
}

/// Runs `claude` with the given args and returns what it printed, or null
/// when it couldn't be run at all. The real source spawns the binary; tests
/// inject a fake (see [CliUsageSource.withRunner]) so failure classification
/// can be exercised without Claude Code installed.
typedef CliRunner = Future<CliOutput?> Function(List<String> args);

/// How a "Sign in…" attempt ended (see [CliUsageSource.signIn]).
enum SignInOutcome { signedIn, cancelled, failed }

class SignInResult {
  final SignInOutcome outcome;

  /// Why it failed, phrased for the popover. Null unless [outcome] is
  /// [SignInOutcome.failed].
  final String? message;

  const SignInResult._(this.outcome, [this.message]);

  const SignInResult.failed(String message)
    : this._(SignInOutcome.failed, message);

  static const signedIn = SignInResult._(SignInOutcome.signedIn);
  static const cancelled = SignInResult._(SignInOutcome.cancelled);
}

/// One sign-in attempt, so a cancel — or a newer attempt — stops exactly it.
class _SignInAttempt {
  bool cancelled = false;
  Process? process;

  void cancel() {
    cancelled = true;
    final proc = process;
    if (proc != null) _terminate(proc);
  }
}

/// SIGTERM first so the CLI can close its localhost callback listener, then
/// SIGKILL in case it ignored that.
void _terminate(Process proc) {
  proc.kill();
  Timer(const Duration(seconds: 3), () => proc.kill(ProcessSignal.sigkill));
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
  CliUsageSource({DateTime Function()? now}) : this._(now: now);

  /// A source whose CLI runs are answered by [runner] instead of a spawned
  /// binary — hermetic, so it is exempt from the FLUTTER_TEST guard.
  @visibleForTesting
  CliUsageSource.withRunner(CliRunner runner, {DateTime Function()? now})
    : this._(now: now, runner: runner);

  CliUsageSource._({DateTime Function()? now, CliRunner? runner})
    : _now = now ?? DateTime.now,
      _runner = runner;

  final DateTime Function() _now;

  /// Test seam: when set, it answers every CLI run (and stands in for
  /// finding the binary).
  final CliRunner? _runner;

  /// flutter_tester would happily spawn the real CLI on the dev machine, so
  /// anything that would is short-circuited there — unless a fake runner
  /// was injected, which is hermetic already.
  bool get _underTest =>
      _runner == null && Platform.environment['FLUTTER_TEST'] == 'true';

  /// Resolved path of the `claude` binary. Null = not searched yet, empty =
  /// searched and absent (so the candidates are only walked once per run).
  String? _binary;

  /// Last good plan label from `claude auth status`. Only a fallback for the
  /// odd probe hiccup — the label is re-probed on every fetch, because the
  /// user can switch Claude Code accounts mid-run (e.g. Max ↔ Team) and a
  /// run-long cache left the badge showing the previous account's plan until
  /// ClaudeBar was restarted.
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
    // Keep widget tests hermetic. noCredentials renders the same harmless
    // "Sign in" state tests saw before.
    if (_underTest) {
      return const CliUsageResult.fail(UsageError.noCredentials);
    }

    if (await _resolveBinary() == null) {
      return const CliUsageResult.fail(UsageError.cliMissing);
    }

    final probe = await _exec(['-p', '/usage', '--output-format', 'json']);
    final out = probe != null && probe.ok ? probe.stdout : null;
    String? text;
    // What the CLI itself said when it failed — an error envelope's result, or
    // a failed run's output — for spotting a dead login. Never a clean run's
    // stray output: an MCP server grumbling about ITS OWN login there must
    // not send the user off to re-sign-in Claude Code.
    final complaints = <String>[
      if (probe != null && !probe.ok) ...[probe.stdout, probe.stderr],
    ];
    // True once the CLI hands back a successful envelope with a string result —
    // i.e. it ran fine and answered. Distinguishes "answered but no usage lines"
    // (a transient empty reply → noData) from "the CLI itself failed" (offline /
    // crashed / format changed), which _classifyFailure handles separately.
    var gotReply = false;
    if (out != null) {
      final envelope = decodeEnvelope(out);
      if (envelope == null) {
        // Exit 0 but nothing JSON-shaped came back.
        Diag.log('usage envelope undecodable: ${_snippet(out)}');
      } else if (envelope['is_error'] == true || envelope['result'] is! String) {
        // The common real-world failure: the CLI exits 0 and hands back an
        // ERROR envelope. Without this line the probe log looks perfectly
        // healthy (two probes, exit=0) while the menu bar sits grey saying
        // "Couldn't read usage" — the CLI's own message was thrown away.
        Diag.log('usage envelope is_error='
            '${envelope['is_error']} subtype=${envelope['subtype']} '
            'result=${_snippet('${envelope['result']}')}');
        complaints.add('${envelope['result']}');
      }
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
      Diag.log('usage text unparsable: ${_snippet(text)}');
    }
    return CliUsageResult.fail(await _classifyFailure(
      gotReply: gotReply,
      // A CLI that knows its login is dead says so in its own reply or error
      // ("… · Please run /login").
      reply: [if (text != null) text, ...complaints].join('\n'),
    ));
  }

  /// First [max] characters of [raw], newlines flattened — enough to identify
  /// what came back without dumping a whole reply into the system log.
  static String _snippet(String raw, [int max = 300]) {
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }

  /// Runs only when a probe failed (rare): works out *why*, so each cause
  /// gets the right message instead of a generic error. [gotReply] means the
  /// CLI answered with a string result that simply lacked the usage lines;
  /// [reply] is what the CLI itself said (its reply, or its error), for
  /// spotting a dead login.
  Future<UsageError> _classifyFailure({
    required bool gotReply,
    required String reply,
  }) async {
    // Signed out? `auth status` is answered locally, so it works offline.
    // This is also where an EXPIRED login lands: when the CLI's refresh token
    // is rejected it wipes the stored token, after which it reads as signed
    // out — so one check covers "never signed in", "signed out" and "login
    // expired". (Claude Desktop signs in separately and can look perfectly
    // healthy meanwhile, which is how this goes unnoticed.)
    final status = await _authStatus();
    if (status?['loggedIn'] == false) return UsageError.noCredentials;
    // Signed in on paper, but the CLI itself says the login is no good — a
    // revoked token it hasn't wiped yet.
    if (mentionsSignIn(reply)) return UsageError.noCredentials;
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

  /// Phrases Claude Code uses when its own login is the problem — `Not
  /// logged in · Please run /login`, `OAuth token revoked · Please run
  /// /login`, `Login expired · Please run /login`, `Not logged in. Run claude
  /// auth login to authenticate.`, or an API `authentication_error`.
  /// Deliberately narrow: a bare "not logged in" could be anything's login
  /// (every Claude Code message with it also names `/login` or `claude auth
  /// login`), and "could not refresh your login because another Claude Code
  /// process is refreshing it" is a transient lock — neither is a reason to
  /// send anyone off to sign in again.
  static const _signInMarkers = [
    'run /login',
    'login expired',
    'oauth token revoked',
    'oauth token has expired',
    'run claude auth login',
    'authentication_error',
  ];

  /// True when [reply] is the CLI saying its login is dead (see
  /// [_signInMarkers]).
  @visibleForTesting
  static bool mentionsSignIn(String reply) {
    final lower = reply.toLowerCase();
    return _signInMarkers.any(lower.contains);
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
    UsageWindow? session, weekly;
    // Keyed by label so a duplicated line updates in place; insertion order
    // preserves the CLI's own print order for the UI.
    final models = <String, UsageWindow>{};
    for (final m in _lineRe.allMatches(text)) {
      final qualifier = m.group(2)?.trim();
      final percent =
          (double.tryParse(m.group(3)!) ?? 0).clamp(0, 100).toDouble();
      final resetsAt = _parseReset(m.group(4), now);

      UsageWindow window(String label) =>
          UsageWindow(percent: percent, resetsAt: resetsAt, label: label);

      if (m.group(1) == 'session') {
        session = window('Session · 5h');
      } else if (qualifier == null) {
        continue;
      } else if (qualifier.toLowerCase() == 'all models') {
        // Matched exactly (not `contains('all')`) so a model whose name
        // happens to contain "all" can never swallow the weekly total.
        weekly = window('Weekly · 7d');
      } else {
        // Any other qualifier is a per-model window — `Opus only`,
        // `Sonnet only`, `Fable only`, whatever the CLI prints next. The
        // label keeps the CLI's own model name, so new models surface
        // without a ClaudeBar update.
        final label = '${_stripOnly(qualifier)} · weekly';
        models[label] = window(label);
      }
    }
    if (session == null || weekly == null) return null;
    return UsageSnapshot(
      session: session,
      weekly: weekly,
      models: List.unmodifiable(models.values),
      plan: plan,
      fetchedAt: now,
    );
  }

  /// `Opus only` → `Opus`; leaves a qualifier without the suffix untouched.
  static String _stripOnly(String qualifier) {
    const suffix = ' only';
    return qualifier.toLowerCase().endsWith(suffix)
        ? qualifier.substring(0, qualifier.length - suffix.length).trimRight()
        : qualifier;
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

  /// Decodes the CLI's JSON envelope out of a reply that may carry noise
  /// around it (shell profiles, Node warnings, MCP server chatter).
  ///
  /// Anchoring on the FIRST `{` and decoding to the end of the output is not
  /// enough on either side:
  ///
  /// - Noise BEFORE the envelope that merely CONTAINS a brace — e.g.
  ///   `…listTools() called but server does not advertise {tools} capability…`
  ///   from an MCP server — makes that decode fail, and the whole reply is
  ///   thrown away.
  /// - Noise AFTER the envelope is trailing garbage, which `jsonDecode`
  ///   rejects just as hard.
  ///
  /// Either way the reply reads downstream as "the CLI produced nothing
  /// parsable", i.e. a format change, and the menu bar goes grey with
  /// "Couldn't read usage" while a perfectly good reading sits in the output.
  /// It's intermittent, because whether an MCP server chats at all varies run
  /// to run — which is exactly how the grey episodes showed up.
  ///
  /// So walk every `{`, trying the rest of the output and then just the rest
  /// of that line (print mode emits the envelope as one line, so the line form
  /// survives trailing noise), and keep the first object that looks like the
  /// envelope. Any other decodable object is only a fallback.
  @visibleForTesting
  static Map<String, dynamic>? decodeEnvelope(String raw) {
    // Enough to clear any realistic preamble without turning a pathological
    // reply into a decode storm.
    const maxCandidates = 64;
    Map<String, dynamic>? fallback;

    Map<String, dynamic>? tryDecode(String text) {
      try {
        final decoded = jsonDecode(text.trim());
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    }

    var start = raw.indexOf('{');
    for (var tried = 0; start >= 0 && tried < maxCandidates; tried++) {
      final lineEnd = raw.indexOf('\n', start);
      for (final candidate in [
        raw.substring(start),
        if (lineEnd > start) raw.substring(start, lineEnd),
      ]) {
        final map = tryDecode(candidate);
        if (map == null) continue;
        // The print-mode envelope always carries these; a stray JSON log line
        // from some tool does not.
        if (map.containsKey('result') ||
            map.containsKey('session_id') ||
            map['type'] == 'result' ||
            map.containsKey('loggedIn') ||
            map.containsKey('subscriptionType')) {
          return map;
        }
        fallback ??= map;
      }
      start = raw.indexOf('{', start + 1);
    }
    return fallback;
  }

  // ---- process plumbing ----

  /// Runs `claude` with [args] to completion (or [_timeout]) and returns what
  /// it printed WHATEVER the exit code — callers decide what a non-zero exit
  /// means. Null only when the CLI couldn't be run at all.
  Future<CliOutput?> _exec(List<String> args) async {
    final runner = _runner;
    if (runner != null) return runner(args);
    final bin = await _resolveBinary();
    if (bin == null) return null;
    // Bracket every child process we spawn on the diagnostic timeline. The
    // refresh timer fires on a fixed cadence, so if a phantom input-source
    // change keeps landing between these two lines, the probe — not focus —
    // is the thing to chase. (See FocusSentinel in MainFlutterWindow.swift.)
    Diag.log('probe start: ${args.join(' ')}');
    try {
      final proc = await Process.start(
        bin,
        args,
        workingDirectory: _ensureProbeDir(),
        environment: childEnvironment(),
        // The sanitising in childEnvironment only takes effect if the parent
        // environment is NOT merged back in on top of it.
        includeParentEnvironment: false,
      );
      final outF = proc.stdout.transform(utf8.decoder).join();
      final errF = proc.stderr.transform(utf8.decoder).join();
      final exit = await proc.exitCode.timeout(_timeout, onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
      final out = await outF;
      final err = await _drained(errF);
      Diag.log('probe done: ${args.first} exit=$exit');
      if (exit != 0 && err.trim().isNotEmpty) {
        // Diag, not debugPrint: debugPrint is stripped from release builds,
        // which is exactly where a user's failing probe needs explaining.
        Diag.log('probe stderr: ${args.first} — ${_snippet(err.trim())}');
      }
      return CliOutput(exit, out, err);
    } catch (e) {
      Diag.log('probe failed: ${args.first} — $e');
      return null;
    }
  }

  /// A finished run's diagnostic stream (stderr, or stdout nobody parses),
  /// waited on only briefly: the CLI has already exited, and a detached
  /// grandchild still holding the pipe open must never stall a probe on
  /// output that is only ever logged.
  static Future<String> _drained(Future<String> stream) =>
      stream.timeout(const Duration(seconds: 2), onTimeout: () => '');

  /// `claude auth status --json`, decoded — null when the probe couldn't run
  /// or printed nothing JSON-shaped.
  ///
  /// Read whatever the exit code: the CLI ends this command with
  /// `exit(loggedIn ? 0 : 1)`, so the one answer that says "signed out"
  /// always arrives as a FAILED run. Dropping non-zero runs, as every probe
  /// here used to, threw exactly that answer away — so an expired Claude Code
  /// login showed up as "No fresh reading" / "Couldn't read usage", with
  /// nothing pointing at the actual fix (sign in again).
  Future<Map<String, dynamic>?> _authStatus() async {
    final out = await _exec(['auth', 'status', '--json']);
    return out == null ? null : decodeEnvelope(out.stdout);
  }

  /// Finds the `claude` binary once per run: well-known install locations
  /// first, then a login shell as the last resort (GUI apps don't inherit
  /// the user's PATH).
  Future<String?> _resolveBinary() async {
    if (_runner != null) return 'claude';
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
      final r = await Process.run(
        '/bin/zsh',
        ['-lc', 'command -v claude'],
        // Same sanitising as the probes themselves — this login shell is a
        // child of a GUI app too (see childEnvironment).
        environment: childEnvironment(),
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 5));
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

  /// Environment for a spawned probe: everything ClaudeBar itself has, minus
  /// the CoreFoundation variables macOS injects into a GUI app's environment.
  ///
  /// `__CFBundleIdentifier` is the one that matters. macOS sets it on a bundled
  /// app's process, and Dart's default `Process.start` hands the parent's whole
  /// environment to the child — so every `claude` probe started with
  /// CoreFoundation believing that plain CLI child was part of ClaudeBar's
  /// bundle, i.e. part of the GUI session, rather than an ordinary background
  /// tool. That is the difference between a child that quietly runs and a child
  /// that registers with the session's text-input machinery on startup; a new
  /// text-input client makes macOS re-assert the system keyboard layout, which
  /// draws the input-source capsule at whatever caret the user is typing in.
  ///
  /// Which matches what was actually observed: the capsule kept appearing on
  /// the refresh cadence with the cursor sitting still, ClaudeBar never took
  /// focus (FocusSentinel logged no key-window or activation events at all),
  /// and quitting ClaudeBar stopped it outright.
  ///
  /// `__CFBundleVersion` / `__CFBundleShortVersionString` ride along from the
  /// same source and are just as wrong to leak into a child, so they go too.
  @visibleForTesting
  Map<String, String> childEnvironment() {
    return Map<String, String>.from(Platform.environment)
      ..remove('__CFBundleIdentifier')
      ..remove('__CFBundleVersion')
      ..remove('__CFBundleShortVersionString')
      // npm-installed `claude` is a Node script — make sure `node` resolves
      // even though GUI apps launch with a minimal PATH.
      ..['PATH'] = _augmentedPath();
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
  /// e.g. "max" → "Max". Probed on every fetch so an account switch shows up
  /// on the next refresh — the CLI answers it locally (no API call), so the
  /// extra spawn costs ~half a second alongside the /usage probe itself. On a
  /// failed probe the last good label is kept ("Claude" before the first).
  Future<String> _planLabel() async {
    final sub = (await _authStatus())?['subscriptionType'];
    if (sub is! String || sub.isEmpty) return _plan ?? 'Claude';
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

  // ---- sign-in ----

  /// How long a browser sign-in may sit unfinished before ClaudeBar gives up
  /// on it. Generous — 2FA and SSO take a while — and Cancel is always there.
  static const _signInTimeout = Duration(minutes: 10);

  /// The same for a sign-in running in a Terminal window.
  static const _terminalSignInTimeout = Duration(minutes: 15);

  /// The sign-in in flight, if any — at most one at a time.
  _SignInAttempt? _signIn;

  /// Signs Claude Code back in by running `claude auth login` headless.
  ///
  /// No terminal needed: the CLI opens the browser itself and waits on a
  /// localhost callback, so the user approves in the browser, the CLI stores
  /// the new token in its own Keychain item (ClaudeBar still never touches
  /// it), prints "Login successful." and exits 0. Without a TTY the CLI
  /// never switches to its paste-a-code prompt, and closing stdin only
  /// aborts that TTY flow — so stdin is simply left open and unused.
  Future<SignInResult> signIn() async {
    if (_underTest) {
      return const SignInResult.failed('Sign-in isn’t available in tests.');
    }
    final bin = await _resolveBinary();
    if (bin == null) return SignInResult.failed(UsageError.cliMissing.message);

    cancelSignIn();
    final attempt = _signIn = _SignInAttempt();
    Diag.log('sign-in start: auth login (browser)');
    try {
      final proc = await Process.start(
        bin,
        ['auth', 'login'],
        workingDirectory: _ensureProbeDir(),
        // Same sanitised environment as the probes (see childEnvironment).
        environment: childEnvironment(),
        includeParentEnvironment: false,
      );
      attempt.process = proc;
      if (attempt.cancelled) _terminate(proc); // cancelled while spawning
      final outF = proc.stdout.transform(utf8.decoder).join();
      final errF = proc.stderr.transform(utf8.decoder).join();
      var timedOut = false;
      final exit = await proc.exitCode.timeout(_signInTimeout, onTimeout: () {
        timedOut = true;
        _terminate(proc);
        return -1;
      });
      // stdout carries the sign-in URL — drained, never logged.
      await _drained(outF);
      final err = await _drained(errF);
      try {
        await proc.stdin.close();
      } catch (_) {}
      Diag.log('sign-in done: exit=$exit'
          '${attempt.cancelled ? ' (cancelled)' : ''}'
          '${timedOut ? ' (timed out)' : ''}');
      if (attempt.cancelled) return SignInResult.cancelled;
      if (exit == 0) return SignInResult.signedIn;
      if (timedOut) {
        return const SignInResult.failed(
            'Sign-in timed out. Try again when you’re ready.');
      }
      if (err.trim().isNotEmpty) {
        Diag.log('sign-in stderr: ${_snippet(err.trim())}');
      }
      return SignInResult.failed(loginFailureMessage(err, exit));
    } catch (e) {
      Diag.log('sign-in failed to start: $e');
      return const SignInResult.failed('Couldn’t start Claude Code’s sign-in.');
    } finally {
      if (identical(_signIn, attempt)) _signIn = null;
    }
  }

  /// The fallback when the browser hand-off can't finish by itself (say the
  /// sign-in page shows a code to paste): opens Terminal running `claude auth
  /// login`, then waits for the script to hand the CLI's exit code back.
  ///
  /// A `.command` file opened with `open -a Terminal` runs in a new window
  /// without the Automation permission prompt that scripting Terminal through
  /// osascript would trigger. It lives in a fresh private temp directory —
  /// not world-writable /tmp — because ClaudeBar is about to execute it.
  Future<SignInResult> signInInTerminal() async {
    if (_underTest) {
      return const SignInResult.failed('Sign-in isn’t available in tests.');
    }
    final bin = await _resolveBinary();
    if (bin == null) return SignInResult.failed(UsageError.cliMissing.message);

    cancelSignIn();
    final attempt = _signIn = _SignInAttempt();
    Directory? dir;
    try {
      dir = await Directory.systemTemp.createTemp('claudebar-sign-in-');
      final script = File('${dir.path}/Sign in to Claude Code.command');
      final exitCodeFile = File('${dir.path}/exit-code');
      await script.writeAsString(
          signInScript(claude: bin, exitCodeFile: exitCodeFile.path));
      final chmod = await Process.run('/bin/chmod', ['700', script.path]);
      if (chmod.exitCode != 0) {
        Diag.log('sign-in (Terminal): chmod failed — ${chmod.stderr}');
        return const SignInResult.failed(
            'Couldn’t prepare the Terminal sign-in.');
      }
      final open = await Process.run(
        '/usr/bin/open',
        ['-a', 'Terminal', script.path],
        environment: childEnvironment(),
        includeParentEnvironment: false,
      );
      if (open.exitCode != 0) {
        Diag.log('sign-in (Terminal): open failed — ${open.stderr}');
        return const SignInResult.failed('Couldn’t open Terminal.');
      }
      Diag.log('sign-in start: auth login (Terminal)');

      final deadline = DateTime.now().add(_terminalSignInTimeout);
      while (!attempt.cancelled) {
        // The script renames the finished file into place, so a parsable
        // code means it's complete; anything else just isn't there yet.
        if (await exitCodeFile.exists()) {
          final code = int.tryParse((await exitCodeFile.readAsString()).trim());
          if (code != null) {
            Diag.log('sign-in done (Terminal): exit=$code');
            return code == 0
                ? SignInResult.signedIn
                : const SignInResult.failed(
                    'The Terminal sign-in didn’t finish. Try again.');
          }
        }
        if (DateTime.now().isAfter(deadline)) {
          return const SignInResult.failed(
              'Timed out waiting for the Terminal sign-in.');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return SignInResult.cancelled;
    } catch (e) {
      Diag.log('sign-in (Terminal) failed: $e');
      return const SignInResult.failed('Couldn’t start the Terminal sign-in.');
    } finally {
      if (identical(_signIn, attempt)) _signIn = null;
      try {
        await dir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Stops the sign-in in flight, if any: kills a headless `auth login`, or
  /// stops waiting on a Terminal one (that window is the user's to close).
  void cancelSignIn() {
    _signIn?.cancel();
    _signIn = null;
  }

  /// The popover line for a failed `claude auth login` — the CLI's own
  /// `Login failed: <reason>` when it gave one.
  @visibleForTesting
  static String loginFailureMessage(String stderr, int exitCode) {
    final reason =
        RegExp(r'Login failed:\s*(.+)').firstMatch(stderr)?.group(1)?.trim();
    if (reason != null && reason.isNotEmpty) {
      return 'Sign-in didn’t finish: ${_snippet(reason, 160)}';
    }
    final lines = stderr
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isNotEmpty) {
      return 'Sign-in didn’t finish: ${_snippet(lines.last, 160)}';
    }
    return 'Sign-in didn’t finish (Claude Code exited with code $exitCode). '
        'Try again.';
  }

  /// The zsh script the Terminal fallback runs: `claude auth login`, then the
  /// exit code into [exitCodeFile] — written to a side file and renamed into
  /// place so ClaudeBar never reads it half-written. Closing the window
  /// mid-sign-in (SIGHUP) still reports a failure instead of leaving
  /// ClaudeBar waiting out the timeout.
  @visibleForTesting
  static String signInScript({
    required String claude,
    required String exitCodeFile,
  }) {
    String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
    final done = q(exitCodeFile);
    final part = q('$exitCodeFile.part');
    return '''
#!/bin/zsh
# Written by ClaudeBar: signs the Claude Code CLI back in, then hands the exit
# code back to ClaudeBar, which refreshes your usage the moment it lands.
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
report() { print -r -- "\$1" > $part && mv -f $part $done; }
trap 'report 129; exit 129' HUP INT TERM
clear 2>/dev/null
print 'ClaudeBar — signing in to Claude Code'
print
${q(claude)} auth login
code=\$?
trap - HUP INT TERM
report \$code
print
if (( code == 0 )); then
  print 'Signed in. ClaudeBar is refreshing your usage — you can close this window.'
else
  print 'Sign-in didn’t finish. Close this window and try again from ClaudeBar.'
fi
exit \$code
''';
  }
}
