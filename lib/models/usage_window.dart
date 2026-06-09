/// A single usage window (session / weekly / per-model) — a normalized
/// percentage plus an optional reset time. See spec §8.
class UsageWindow {
  /// Normalized to 0..100 by the parser regardless of the source scale.
  final double percent;

  /// When this window's limit resets, if the payload provided it.
  final DateTime? resetsAt;

  /// Display label, e.g. "Session", "Weekly", "Opus · weekly".
  final String label;

  const UsageWindow({
    required this.percent,
    this.resetsAt,
    required this.label,
  });
}
