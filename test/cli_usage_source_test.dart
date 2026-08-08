// Unit tests for the CLI-first usage source: parsing the human text that
// `claude -p "/usage" --output-format json` returns inside its envelope.

import 'package:claude_usage_bar/data/cli_usage_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

    test('returns null on non-JSON output', () {
      expect(CliUsageSource.decodeEnvelope('command not found'), isNull);
      expect(CliUsageSource.decodeEnvelope(''), isNull);
    });
  });
}
