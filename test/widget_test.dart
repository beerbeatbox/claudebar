// Unit tests for ClaudeBar's formatting helpers.

import 'package:claude_usage_bar/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
