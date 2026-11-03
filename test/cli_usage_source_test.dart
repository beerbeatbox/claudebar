// Unit tests for the CLI-first usage source: parsing the human text that
// `claude -p "/usage" --output-format json` returns inside its envelope,
// classifying failed probes, and the sign-in plumbing.

import 'dart:convert';
import 'dart:io';

import 'package:claude_usage_bar/data/cli_usage_source.dart';
import 'package:claude_usage_bar/models/usage_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Diag.log talks to a platform channel; the test binding gives it a
  // (handler-less) messenger to fail quietly against.
  TestWidgetsFlutterBinding.ensureInitialized();

  // Frozen "now" matching the real capture below (local time).
  final now = DateTime(2026, 6, 12, 22, 0);

  // Verbatim `result` text from claude 2.1.170 on 2026-06-12.
  const sample =
      'You are currently using your subscription to power your Claude Code usage\n'
      '\n'
      'Current session: 35% used · resets Jun 13 at 1:49am (Asia/Bangkok)\n'
      'Current week (all models): 28% used · resets Jun 14 at 1:59am (Asia/Bangkok)\n'
      'Current week (Sonnet only): 0% used';

  group('CliUsageSource.childEnvironment', () {
    // Regression guard for the phantom input-source capsule: macOS puts
    // __CFBundleIdentifier in a bundled app's environment, and handing it to a
    // spawned CLI child makes CoreFoundation there believe the child belongs to
    // ClaudeBar's bundle — a GUI-session citizen rather than a background tool,
    // which is what made every refresh flash the language badge at the user's
    // caret. Passing these through must stay a deliberate choice, not a default.
    test('drops the CoreFoundation bundle variables macOS injects', () {
      final env = CliUsageSource().childEnvironment();
      expect(env.containsKey('__CFBundleIdentifier'), isFalse);
      expect(env.containsKey('__CFBundleVersion'), isFalse);
      expect(env.containsKey('__CFBundleShortVersionString'), isFalse);
    });

    test('still hands the child a PATH that can resolve node/claude', () {
      final env = CliUsageSource().childEnvironment();
      expect(env['PATH'], isNotNull);
      expect(env['PATH'], contains('/usr/local/bin'));
    });
  });

  group('CliUsageSource.parseUsageText', () {
    test('parses the real /usage output shape', () {
      final snap =
          CliUsageSource.parseUsageText(sample, plan: 'Max', now: now);
      expect(snap, isNotNull);
      expect(snap!.session.percent, closeTo(35, 0.01));
      expect(snap.session.resetsAt, DateTime(2026, 6, 13, 1, 49));
      expect(snap.session.label, 'Session · 5h');
      expect(snap.weekly.percent, closeTo(28, 0.01));
      expect(snap.weekly.resetsAt, DateTime(2026, 6, 14, 1, 59));
      expect(snap.models, hasLength(1));
      expect(snap.models.single.label, 'Sonnet · weekly');
      expect(snap.models.single.percent, closeTo(0, 0.01));
      expect(snap.models.single.resetsAt, isNull);
      expect(snap.plan, 'Max');
      expect(snap.fetchedAt, now);
    });

    test('parses an Opus-only weekly line and pm times', () {
      const text = 'Current session: 12% used · resets Jun 12 at 11:30pm (UTC)\n'
          'Current week (all models): 40% used\n'
          'Current week (Opus only): 7.5% used';
      final snap = CliUsageSource.parseUsageText(text, plan: 'Max', now: now);
      expect(snap!.session.resetsAt, DateTime(2026, 6, 12, 23, 30));
      expect(snap.weekly.resetsAt, isNull);
      expect(snap.models.single.label, 'Opus · weekly');
      expect(snap.models.single.percent, closeTo(7.5, 0.01));
    });

    test('surfaces every per-model line, in CLI order, without an allowlist',
        () {
      // A model ClaudeBar has never heard of must still get a row — that is
      // the point of the generic parser (no app update per new model).
      const text = 'Current session: 12% used\n'
          'Current week (all models): 40% used\n'
          'Current week (Opus only): 7.5% used\n'
          'Current week (Sonnet only): 3% used\n'
          'Current week (Fable only): 14% used';
      final snap = CliUsageSource.parseUsageText(text, plan: 'Max', now: now);
      expect(
        snap!.models.map((w) => w.label),
        ['Opus · weekly', 'Sonnet · weekly', 'Fable · weekly'],
      );
      expect(snap.models[2].percent, closeTo(14, 0.01));
    });

    test('a model name containing "all" is not mistaken for the weekly total',
        () {
      const text = 'Current session: 1% used\n'
          'Current week (all models): 2% used\n'
          'Current week (Small only): 3% used';
      final snap = CliUsageSource.parseUsageText(text, plan: 'Max', now: now);
      expect(snap!.weekly.percent, closeTo(2, 0.01));
      expect(snap.models.single.label, 'Small · weekly');
    });

    test('rolls the year over a December→January reset', () {
      final dec = DateTime(2026, 12, 30, 22, 0);
      const text = 'Current session: 1% used · resets Dec 31 at 2:00am (X)\n'
          'Current week (all models): 2% used · resets Jan 2 at 1:00am (X)';
      final snap = CliUsageSource.parseUsageText(text, plan: 'Max', now: dec);
      expect(snap!.session.resetsAt, DateTime(2026, 12, 31, 2, 0));
      expect(snap.weekly.resetsAt, DateTime(2027, 1, 2, 1, 0));
    });

    test('treats 12am as midnight', () {
      const text = 'Current session: 1% used · resets Jun 13 at 12:05am (X)\n'
          'Current week (all models): 2% used · resets Jun 13 at 12:05pm (X)';
      final snap = CliUsageSource.parseUsageText(text, plan: 'Max', now: now);
      expect(snap!.session.resetsAt, DateTime(2026, 6, 13, 0, 5));
      expect(snap.weekly.resetsAt, DateTime(2026, 6, 13, 12, 5));
    });

    test('keeps the percent but drops an unrecognized resets phrase', () {
      const text = 'Current session: 9% used · resets in a little while\n'
          'Current week (all models): 2% used';
      final snap = CliUsageSource.parseUsageText(text, plan: 'Max', now: now);
      expect(snap!.session.percent, closeTo(9, 0.01));
      expect(snap.session.resetsAt, isNull);
    });

    test('returns null when the session or weekly line is missing', () {
      expect(
        CliUsageSource.parseUsageText('Current session: 5% used',
            plan: 'Max', now: now),
        isNull,
      );
      expect(
        CliUsageSource.parseUsageText('You are logged out. Run /login.',
            plan: 'Max', now: now),
        isNull,
      );
    });

    test('returns null on the preamble-only reply the GUI probe often gets', () {
      // In a minimal (GUI-launch) environment `claude -p "/usage"` frequently
      // returns just this header — no data lines — and the app must reject it
      // (→ noData), not parse it as a partial snapshot.
      expect(
        CliUsageSource.parseUsageText(
          'You are currently using your subscription to power your Claude Code usage',
          plan: 'Max',
          now: now,
        ),
        isNull,
      );
    });
  });

  group('CliUsageSource.decodeEnvelope', () {
    test('decodes the print-mode JSON envelope, skipping preamble noise', () {
      final env = CliUsageSource.decodeEnvelope(
        'node warning: blah\n{"type":"result","is_error":false,'
        '"result":"text","session_id":"abc"}',
      );
      expect(env, isNotNull);
      expect(env!['result'], 'text');
      expect(env['session_id'], 'abc');
    });

    // The grey-menu-bar regression: an MCP server (or any startup warning)
    // prints a line containing a brace before the envelope. Anchoring on the
    // first `{` made the whole reply undecodable, so a perfectly good reading
    // was reported as "Couldn't read usage".
    test('skips noise that merely contains a brace', () {
      final env = CliUsageSource.decodeEnvelope(
        'client.listTools() called but server does not advertise '
        '{tools} capability - returning empty list\n'
        '{"type":"result","is_error":false,"result":"Current session: 22% used",'
        '"session_id":"abc"}',
      );
      expect(env, isNotNull);
      expect(env!['result'], 'Current session: 22% used');
    });

    test('picks the envelope over a JSON log line printed before it', () {
      final env = CliUsageSource.decodeEnvelope(
        '{"level":"warn","msg":"mcp server slow"}\n'
        '{"type":"result","is_error":false,"result":"text"}',
      );
      expect(env?['result'], 'text');
    });

    test('survives noise printed after the envelope', () {
      final env = CliUsageSource.decodeEnvelope(
        '{"type":"result","is_error":false,"result":"text"}\n'
        'client.listTools() called but server does not advertise {tools}',
      );
      expect(env?['result'], 'text');
    });

    test('returns null on non-JSON output', () {
      expect(CliUsageSource.decodeEnvelope('command not found'), isNull);
      expect(CliUsageSource.decodeEnvelope(''), isNull);
    });
  });

  group('CliUsageSource.fetch failure classification', () {
    // The print-mode envelope, minus session_id so the probe-session cleanup
    // never goes looking under ~/.claude/projects during tests.
    String envelope(String result, {bool isError = false}) => jsonEncode({
          'type': 'result',
          'subtype': isError ? 'error' : 'success',
          'is_error': isError,
          'result': result,
        });

    // Verbatim (pretty-printed) `claude auth status --json` from claude 2.1.x.
    // Signed out, it exits 1 ALONGSIDE this JSON.
    const signedOut = '{\n  "loggedIn": false,\n  "authMethod": "none",\n'
        '  "apiProvider": "firstParty"\n}\n';
    const signedIn = '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n'
        '  "apiProvider": "firstParty",\n  "subscriptionType": "max"\n}\n';

    CliUsageSource sourceWith({
      required CliOutput usage,
      required CliOutput status,
    }) =>
        CliUsageSource.withRunner(
          (args) async => args.first == 'auth' ? status : usage,
          now: () => now,
        );

    // The regression behind "the menu bar stopped updating and nothing said
    // why": `auth status` exits 1 exactly when signed out, and the classifier
    // dropped every non-zero run — so an expired Claude Code login surfaced
    // as "No fresh reading" instead of "Sign in".
    test('reads "signed out" from auth status even though it exits 1',
        () async {
      final source = sourceWith(
        // A signed-out CLI answers /usage with its local cost summary.
        usage: CliOutput(
            0, envelope('Total cost: \$0.0000\nUsage: 0 input, 0 output')),
        status: const CliOutput(1, signedOut),
      );
      final result = await source.fetch();
      expect(result.isOk, isFalse);
      expect(result.error?.kind, UsageErrorKind.noCredentials);
    });

    test('a signed-in CLI with a gated (preamble-only) reply is still noData',
        () async {
      final source = sourceWith(
        usage: CliOutput(
          0,
          envelope('You are currently using your subscription to power your '
              'Claude Code usage'),
        ),
        status: const CliOutput(0, signedIn),
      );
      expect((await source.fetch()).error?.kind, UsageErrorKind.noData);
    });

    test('a CLI that calls its own login dead reads as signed out', () async {
      final source = sourceWith(
        usage: const CliOutput(1, '', 'OAuth token revoked · Please run /login'),
        status: const CliOutput(0, signedIn),
      );
      expect((await source.fetch()).error?.kind, UsageErrorKind.noCredentials);
    });

    test('so does an error envelope naming /login', () async {
      final source = sourceWith(
        usage: CliOutput(
            0, envelope('Not logged in · Please run /login', isError: true)),
        status: const CliOutput(0, signedIn),
      );
      expect((await source.fetch()).error?.kind, UsageErrorKind.noCredentials);
    });

    // Only the CLI's own words count: an MCP server's chatter about its own
    // service, printed around a clean (if gated) reply, must not be read as
    // Claude Code's login being dead.
    test('ignores login talk in a clean run’s stray output', () async {
      final source = sourceWith(
        usage: CliOutput(
          0,
          'MCP server "deploy": Not logged in — please run /login there\n'
          '${envelope('You are currently using your subscription to power '
              'your Claude Code usage')}',
        ),
        status: const CliOutput(0, signedIn),
      );
      expect((await source.fetch()).error?.kind, UsageErrorKind.noData);
    });

    test('a good reading still parses, with the plan from auth status',
        () async {
      final source = sourceWith(
        usage: CliOutput(0, envelope(sample)),
        status: const CliOutput(0, signedIn),
      );
      final result = await source.fetch();
      expect(result.isOk, isTrue);
      expect(result.snapshot!.session.percent, closeTo(35, 0.01));
      expect(result.snapshot!.plan, 'Max');
    });
  });

  group('CliUsageSource.mentionsSignIn', () {
    test('recognises the CLI’s dead-login messages', () {
      for (final msg in [
        'Not logged in · Please run /login',
        'Not logged in · Run /login',
        'OAuth token revoked · Please run /login',
        'Login expired · Please run /login',
        'Not logged in. Run claude auth login to authenticate.',
        'API Error: 401 {"type":"error","error":{"type":"authentication_error",'
            '"message":"Invalid bearer token"}}',
        'OAuth token has expired. Please obtain a new token.',
      ]) {
        expect(CliUsageSource.mentionsSignIn(msg), isTrue, reason: msg);
      }
    });

    test('ignores ordinary replies and transient refresh trouble', () {
      for (final msg in [
        sample,
        'You are currently using your subscription to power your Claude Code '
            'usage',
        'Total cost: \$0.0000',
        // Some other tool's login, not Claude Code's.
        'Error: Not logged in to Vercel',
        // Another Claude Code process holds the refresh lock: retry, don't
        // send the user off to sign in again.
        'Could not refresh your login because another Claude Code process is '
            'refreshing it (or exited mid-refresh) · Try again in a minute; if '
            'it keeps happening, close other Claude Code windows or sign in '
            'again with /login',
        '',
      ]) {
        expect(CliUsageSource.mentionsSignIn(msg), isFalse, reason: msg);
      }
    });
  });

  group('CliUsageSource.loginFailureMessage', () {
    test('surfaces the CLI’s own reason', () {
      expect(
        CliUsageSource.loginFailureMessage(
            'Login failed: Request failed with status code 403\n', 1),
        'Sign-in didn’t finish: Request failed with status code 403',
      );
    });

    test('falls back to the last stderr line, then to the exit code', () {
      expect(
        CliUsageSource.loginFailureMessage('warn: slow\nsomething broke\n', 1),
        'Sign-in didn’t finish: something broke',
      );
      expect(CliUsageSource.loginFailureMessage('', 7), contains('code 7'));
    });
  });

  group('CliUsageSource.signInScript', () {
    test('single-quotes every path, apostrophes included', () {
      final script = CliUsageSource.signInScript(
        claude: "/Users/o'neil/My Tools/claude",
        exitCodeFile: '/var/folders/x/T/claudebar-sign-in-1/exit-code',
      );
      expect(script, startsWith('#!/bin/zsh\n'));
      expect(script, contains(r"'/Users/o'\''neil/My Tools/claude' auth login"));
      expect(
        script,
        contains("mv -f '/var/folders/x/T/claudebar-sign-in-1/exit-code.part' "
            "'/var/folders/x/T/claudebar-sign-in-1/exit-code'"),
      );
    });

    // Run the real script under zsh against a stand-in `claude` (macOS always
    // has /bin/zsh; elsewhere these skip).
    final zsh = File('/bin/zsh').existsSync()
        ? '/bin/zsh'
        : (File('/usr/bin/zsh').existsSync() ? '/usr/bin/zsh' : null);

    Future<({int exit, String? reported})> run(
      String fakeClaude, {
      bool hangUp = false,
    }) async {
      final dir = await Directory.systemTemp.createTemp('claudebar-script-');
      addTearDown(() => dir.delete(recursive: true));
      // A space in the path on purpose: it must survive the quoting.
      final claude = File('${dir.path}/fake claude');
      await claude.writeAsString('#!/bin/sh\n'
          '[ "\$1 \$2" = "auth login" ] || exit 99\n'
          '$fakeClaude\n');
      await Process.run('chmod', ['755', claude.path]);
      final exitCodeFile = '${dir.path}/exit-code';
      final script = File('${dir.path}/sign-in.command');
      await script.writeAsString(CliUsageSource.signInScript(
          claude: claude.path, exitCodeFile: exitCodeFile));

      final proc = await Process.start(zsh!, [script.path]);
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
      if (hangUp) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        proc.kill(ProcessSignal.sighup); // the Terminal window was closed
      }
      final exit = await proc.exitCode;
      final reported = File(exitCodeFile);
      return (
        exit: exit,
        reported:
            reported.existsSync() ? reported.readAsStringSync().trim() : null,
      );
    }

    final skip = zsh == null ? 'zsh is not installed' : false;

    test('hands a successful sign-in back as exit code 0', () async {
      final r = await run('exit 0');
      expect(r.reported, '0');
      expect(r.exit, 0);
    }, skip: skip);

    test('hands a failed sign-in back with the CLI’s exit code', () async {
      final r = await run('exit 3');
      expect(r.reported, '3');
      expect(r.exit, 3);
    }, skip: skip);

    test('closing the window mid-sign-in still reports a failure', () async {
      final r = await run('sleep 1', hangUp: true);
      expect(r.reported, '129');
    }, skip: skip);
  });
}
