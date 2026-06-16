import 'package:intl/intl.dart';

/// Formatting helpers for reset countdowns and timestamps (spec §9).
class Fmt {
  /// "Resets in 2h 14m" when under ~24h away, otherwise "Resets Sat 00:00".
  /// Returns null when there's no reset time to show.
  static String? resets(DateTime? resetsAt, {DateTime? now}) {
    if (resetsAt == null) return null;
    final current = now ?? DateTime.now();
    final diff = resetsAt.difference(current);

    if (diff.isNegative) return 'Resets 0m';

    if (diff.inHours < 24) {
      final h = diff.inHours;
      final m = diff.inMinutes % 60;
      if (h == 0) return 'Resets in ${m}m';
      return 'Resets in ${h}h ${m}m';
    }

    return 'Resets ${DateFormat('EEE HH:mm').format(resetsAt)}';
  }

  /// Compact countdown for the menu-bar title — "2h05m", "45m", or "3d4h"
  /// for far-off (weekly) resets. Null when there's no reset time; bottoms out
  /// at "0m" once the reset moment has passed but a fresh snapshot hasn't landed.
  static String? countdownShort(DateTime? resetsAt, {DateTime? now}) {
    if (resetsAt == null) return null;
    final diff = resetsAt.difference(now ?? DateTime.now());

    if (diff.isNegative) return '0m';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) {
      return '${diff.inHours}h${(diff.inMinutes % 60).toString().padLeft(2, '0')}m';
    }
    return '${diff.inDays}d${diff.inHours % 24}h';
  }

  /// "Updated 14:32".
  static String updated(DateTime when) => 'Updated ${DateFormat('HH:mm').format(when)}';

  /// "As of 13:50" — for stale readings.
  static String asOf(DateTime when) => 'As of ${DateFormat('HH:mm').format(when)}';

  /// Whole-number percent with a % sign, e.g. "42%".
  static String pct(double percent) => '${percent.round()}%';
}
