import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/usage_snapshot.dart';
import '../settings/prefs.dart';

/// One historical reading — just the two headline percentages and when it was
/// taken. Kept deliberately small: the store holds hundreds of these, and the
/// forecast only needs the recent tail.
class UsageSample {
  final DateTime at;
  final double session;
  final double weekly;

  const UsageSample({
    required this.at,
    required this.session,
    required this.weekly,
  });

  Map<String, dynamic> toJson() => {
    't': at.millisecondsSinceEpoch,
    's': session,
    'w': weekly,
  };

  static UsageSample? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['t'];
    final s = raw['s'];
    final w = raw['w'];
    if (t is! int || s is! num || w is! num) return null;
    return UsageSample(
      at: DateTime.fromMillisecondsSinceEpoch(t),
      session: s.toDouble(),
      weekly: w.toDouble(),
    );
  }
}

/// A rolling log of usage readings persisted to SharedPreferences, feeding the
/// burn-rate forecast. Refreshes land every few minutes, so even a day of
/// history is only a few hundred samples — we cap by age and count anyway so
/// the stored JSON can't grow without bound.
class UsageHistory {
  final SharedPreferences _prefs;

  static const _key = 'usageHistory';
  static const _maxAge = Duration(days: 7);
  static const _maxSamples = 2500;

  UsageHistory(this._prefs);

  /// All retained samples, oldest first.
  List<UsageSample> get samples {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(UsageSample.fromJson)
          .whereType<UsageSample>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Appends a reading from [snapshot] and prunes anything older than [_maxAge]
  /// or beyond [_maxSamples]. Stale (offline) snapshots are skipped — they'd
  /// repeat the last real value and flatten the burn rate.
  Future<void> add(UsageSnapshot snapshot, {DateTime? now}) async {
    if (snapshot.stale) return;
    final at = now ?? DateTime.now();
    final cutoff = at.subtract(_maxAge);

    final next = [
      ...samples.where((s) => s.at.isAfter(cutoff)),
      UsageSample(
        at: at,
        session: snapshot.session.percent,
        weekly: snapshot.weekly.percent,
      ),
    ];

    final trimmed = next.length > _maxSamples
        ? next.sublist(next.length - _maxSamples)
        : next;

    await _prefs.setString(
      _key,
      jsonEncode(trimmed.map((s) => s.toJson()).toList()),
    );
  }
}

final usageHistoryProvider = Provider<UsageHistory>(
  (ref) => UsageHistory(ref.read(sharedPreferencesProvider)),
);
