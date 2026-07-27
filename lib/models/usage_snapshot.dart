import 'usage_window.dart';

/// A full reading of the OAuth usage endpoint at a point in time (spec §8).
class UsageSnapshot {
  final UsageWindow session;
  final UsageWindow weekly;

  /// Per-model weekly windows (`Current week (<Model> only): …`), in the
  /// order the CLI printed them. Parsed generically so a plan's models —
  /// Opus, Sonnet, Fable, whatever ships next — all surface without a code
  /// change; empty when the payload has none (UI hides the section; not an
  /// error).
  final List<UsageWindow> models;

  /// Plan label from `claude auth status`, e.g. "Max", "Pro".
  final String plan;

  final DateTime fetchedAt;

  /// True when this snapshot is being shown despite a failed refresh (offline).
  final bool stale;

  const UsageSnapshot({
    required this.session,
    required this.weekly,
    this.models = const [],
    required this.plan,
    required this.fetchedAt,
    this.stale = false,
  });

  UsageSnapshot copyWith({DateTime? fetchedAt, bool? stale}) {
    return UsageSnapshot(
      session: session,
      weekly: weekly,
      models: models,
      plan: plan,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      stale: stale ?? this.stale,
    );
  }
}
