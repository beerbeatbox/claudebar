import '../models/usage_snapshot.dart';
import 'usage_history.dart';

/// A burn-rate projection for the session window: how fast usage is climbing
/// and, if it keeps up, when it would hit 100%.
class Forecast {
  /// Percentage points consumed per hour, computed over the current window's
  /// recent samples. Always >= 0.
  final double ratePerHour;

  /// When the session window is projected to reach 100%, or null when it isn't
  /// climbing fast enough to ever get there (or there's too little history).
  final DateTime? full;

  const Forecast({required this.ratePerHour, this.full});

  /// True when the rate is meaningful enough to surface to the user. Below this
  /// the projection is noise — a flat or barely-moving window.
  bool get usable => ratePerHour >= _minRate;

  /// Minimum samples must span this long before a rate is trustworthy — guards
  /// against a wild slope from two readings a minute apart.
  static const _minSpan = Duration(minutes: 6);

  /// Below ~2 %/hr the window is effectively idle; don't forecast.
  static const _minRate = 2.0;

  /// Projects from the [snapshot]'s session window using [samples]. Only the
  /// tail belonging to the *current* window is used: a drop in percentage means
  /// the window reset, so anything before that drop is discarded.
  static Forecast? compute(
    UsageSnapshot snapshot,
    List<UsageSample> samples, {
    DateTime? now,
  }) {
    final current = snapshot.session.percent;
    final at = now ?? DateTime.now();

    // Walk back from the latest sample while readings stay non-decreasing; the
    // first drop marks the previous window's reset. A small tolerance absorbs
    // parser rounding jitter.
    final anchor = _windowStart(samples);
    if (anchor == null) return null;

    final spanned = at.difference(anchor.at);
    if (spanned < _minSpan) return null;

    final climbed = current - anchor.session;
    if (climbed <= 0) return const Forecast(ratePerHour: 0);

    final rate = climbed / (spanned.inSeconds / 3600);
    if (rate < _minRate) return Forecast(ratePerHour: rate);

    final remaining = 100 - current;
    if (remaining <= 0) return Forecast(ratePerHour: rate, full: at);

    final secondsToFull = (remaining / rate) * 3600;
    return Forecast(
      ratePerHour: rate,
      full: at.add(Duration(seconds: secondsToFull.round())),
    );
  }

  /// The earliest sample in the contiguous non-decreasing run that ends at the
  /// most recent reading — i.e. the start of the window currently in progress.
  static UsageSample? _windowStart(List<UsageSample> samples) {
    if (samples.length < 2) return null;
    const tolerance = 1.0; // percentage points of acceptable jitter
    var start = samples.length - 1;
    for (var i = samples.length - 1; i > 0; i--) {
      if (samples[i].session < samples[i - 1].session - tolerance) break;
      start = i - 1;
    }
    if (start == samples.length - 1) return null;
    return samples[start];
  }
}
