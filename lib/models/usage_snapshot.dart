import 'usage_window.dart';

/// A full reading of the OAuth usage endpoint at a point in time (spec §8).
class UsageSnapshot {
  final UsageWindow session;
  final UsageWindow weekly;

  /// Per-model weekly windows — null when the payload omits them (UI hides
  /// those rows; not an error).
  final UsageWindow? sonnet;
  final UsageWindow? opus;

  /// Plan label from `claude auth status`, e.g. "Max", "Pro".
  final String plan;

  final DateTime fetchedAt;

  /// True when this snapshot is being shown despite a failed refresh (offline).
  final bool stale;

  const UsageSnapshot({
    required this.session,
    required this.weekly,
    this.sonnet,
    this.opus,
    required this.plan,
    required this.fetchedAt,
    this.stale = false,
  });

  UsageSnapshot copyWith({DateTime? fetchedAt, bool? stale}) {
    return UsageSnapshot(
      session: session,
      weekly: weekly,
      sonnet: sonnet,
      opus: opus,
      plan: plan,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      stale: stale ?? this.stale,
    );
  }
}
