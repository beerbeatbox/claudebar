// Unit tests for ClaudeBar's data parsing and formatting helpers.

import 'package:claude_usage_bar/data/usage_api.dart';
import 'package:claude_usage_bar/models/credentials.dart';
import 'package:claude_usage_bar/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ClaudeCredentials.fromJson', () {
    test('parses the nested claudeAiOauth envelope', () {
      final creds = ClaudeCredentials.fromJson({
        'claudeAiOauth': {
          'accessToken': 'sk-ant-oat01-abc',
          'scopes': ['user:inference', 'user:profile'],
          'subscriptionType': 'max',
          'expiresAt': 1760000000000,
        },
      });
      expect(creds, isNotNull);
      expect(creds!.canReadUsage, isTrue);
      expect(creds.planLabel, 'Max');
    });

    test('flags a token missing user:profile', () {
      final creds = ClaudeCredentials.fromJson({
        'accessToken': 'sk-ant-oat01-abc',
        'scopes': ['user:inference'],
      });
      expect(creds!.canReadUsage, isFalse);
    });
  });

  group('UsageApi parsing', () {
    test('reads 0–100 utilization, ISO resets_at, and null windows', () async {
      // Shape verified against the live endpoint: utilization is already
      // 0–100, resets_at is ISO8601 (or null), and per-model windows may be
      // null even when others are present.
      final client = MockClient((req) async {
        return http.Response(
          '{"five_hour":{"utilization":24.0,"resets_at":"2026-06-09T18:29:59.741707+00:00"},'
          '"seven_day":{"utilization":12.0,"resets_at":"2026-06-13T19:00:00+00:00"},'
          '"seven_day_opus":null,'
          '"seven_day_sonnet":{"utilization":0.0,"resets_at":null}}',
          200,
        );
      });
      final api = UsageApi(client: client);
      final result = await api.fetch(const ClaudeCredentials(
        accessToken: 't',
        scopes: ['user:profile'],
        subscriptionType: 'max',
      ));
      expect(result.isOk, isTrue);
      expect(result.snapshot!.session.percent, closeTo(24, 0.01));
      expect(result.snapshot!.session.resetsAt, isNotNull);
      expect(result.snapshot!.weekly.percent, closeTo(12, 0.01));
      expect(result.snapshot!.opus, isNull);
      expect(result.snapshot!.sonnet!.percent, closeTo(0, 0.01));
      expect(result.snapshot!.sonnet!.resetsAt, isNull);
    });

    test('does not inflate a genuine low percentage', () async {
      final client = MockClient((req) async => http.Response(
            '{"five_hour":{"utilization":0.5},"seven_day":{"utilization":3.0}}',
            200,
          ));
      final result = await UsageApi(client: client).fetch(const ClaudeCredentials(
        accessToken: 't',
        scopes: ['user:profile'],
      ));
      expect(result.snapshot!.session.percent, closeTo(0.5, 0.01));
    });

    test('maps 401 to the expired-token error', () async {
      final client = MockClient((req) async => http.Response('', 401));
      final api = UsageApi(client: client);
      final result = await api.fetch(const ClaudeCredentials(
        accessToken: 't',
        scopes: ['user:profile'],
      ));
      expect(result.isOk, isFalse);
      expect(result.error!.message, contains('expired'));
    });
  });

  group('Fmt.resets', () {
    test('renders hours and minutes when within a day', () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final resets = now.add(const Duration(hours: 2, minutes: 14));
      expect(Fmt.resets(resets, now: now), 'Resets in 2h 14m');
    });

    test('returns null without a reset time', () {
      expect(Fmt.resets(null), isNull);
    });
  });

  group('Fmt.countdownShort', () {
    final now = DateTime(2026, 1, 1, 12, 0);

    test('renders compact h/m with padded minutes', () {
      expect(
        Fmt.countdownShort(now.add(const Duration(hours: 2, minutes: 14)), now: now),
        '2h14m',
      );
      expect(
        Fmt.countdownShort(now.add(const Duration(hours: 3, minutes: 5)), now: now),
        '3h05m',
      );
    });

    test('drops the hour part under an hour', () {
      expect(Fmt.countdownShort(now.add(const Duration(minutes: 45)), now: now), '45m');
    });

    test('uses d/h for far-off weekly resets', () {
      expect(
        Fmt.countdownShort(now.add(const Duration(days: 3, hours: 4, minutes: 30)), now: now),
        '3d4h',
      );
    });

    test('handles missing and past reset times', () {
      expect(Fmt.countdownShort(null), isNull);
      expect(
        Fmt.countdownShort(now.subtract(const Duration(minutes: 1)), now: now),
        'soon',
      );
    });
  });
}
