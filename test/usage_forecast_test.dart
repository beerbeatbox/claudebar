// Unit tests for the burn-rate forecast.

import 'package:claude_usage_bar/data/usage_forecast.dart';
import 'package:claude_usage_bar/data/usage_history.dart';
import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:flutter_test/flutter_test.dart';

UsageSnapshot _snap(double session, {DateTime? resetsAt}) => UsageSnapshot(
  session: UsageWindow(percent: session, resetsAt: resetsAt, label: 'Session'),
  weekly: const UsageWindow(percent: 0, label: 'Weekly'),
  plan: 'Max',
  fetchedAt: DateTime(2026, 1, 1, 12),
);

UsageSample _sample(DateTime at, double session) =>
    UsageSample(at: at, session: session, weekly: 0);

void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0);

  group('Forecast.compute', () {
    test('returns null with fewer than two samples', () {
      expect(Forecast.compute(_snap(10), [_sample(t0, 10)], now: t0), isNull);
    });

    test('returns null when the samples span less than the minimum window', () {
      final samples = [
        _sample(t0, 10),
        _sample(t0.add(const Duration(minutes: 3)), 14),
      ];
      final now = t0.add(const Duration(minutes: 3));
      expect(Forecast.compute(_snap(14), samples, now: now), isNull);
    });

    test('computes rate and ETA for a steady climb', () {
      // 10% -> 40% over 60 minutes = 30 %/hr; 60% left => full in 2h.
      final samples = [
        _sample(t0, 10),
        _sample(t0.add(const Duration(minutes: 30)), 25),
        _sample(t0.add(const Duration(minutes: 60)), 40),
      ];
      final now = t0.add(const Duration(minutes: 60));
      final f = Forecast.compute(_snap(40), samples, now: now);

      expect(f, isNotNull);
      expect(f!.ratePerHour, closeTo(30, 0.5));
      expect(f.usable, isTrue);
      expect(f.full, isNotNull);
      // 60 remaining / 30 per hour = 2 hours from now.
      expect(
        f.full!.difference(now).inMinutes,
        closeTo(120, 2),
      );
    });

    test('ignores samples before a reset (percentage drop)', () {
      // An old high run, then a reset down to 5, then a gentle climb.
      final samples = [
        _sample(t0, 80),
        _sample(t0.add(const Duration(minutes: 10)), 90),
        _sample(t0.add(const Duration(minutes: 20)), 5), // reset
        _sample(t0.add(const Duration(minutes: 50)), 11),
      ];
      final now = t0.add(const Duration(minutes: 50));
      final f = Forecast.compute(_snap(11), samples, now: now);

      expect(f, isNotNull);
      // Only the post-reset run counts: 5 -> 11 over 30 min = 12 %/hr.
      expect(f!.ratePerHour, closeTo(12, 0.5));
    });

    test('a flat window is not usable', () {
      final samples = [
        _sample(t0, 30),
        _sample(t0.add(const Duration(minutes: 30)), 30),
      ];
      final now = t0.add(const Duration(minutes: 30));
      final f = Forecast.compute(_snap(30), samples, now: now);

      expect(f, isNotNull);
      expect(f!.ratePerHour, 0);
      expect(f.usable, isFalse);
      expect(f.full, isNull);
    });
  });
}
