import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/usage_snapshot.dart';
import '../models/usage_window.dart';
import '../settings/prefs.dart';
import '../ui/format.dart';
import 'usage_forecast.dart';

/// Holds the plugin instance, overridden in `main()` once it's initialized so
/// the rest of the app reads it synchronously (mirrors [sharedPreferencesProvider]).
final notificationsPluginProvider = Provider<FlutterLocalNotificationsPlugin>(
  (ref) => throw UnimplementedError('notificationsPluginProvider not overridden'),
);

final usageNotifierProvider = Provider<UsageNotifier>(
  (ref) => UsageNotifier(
    plugin: ref.read(notificationsPluginProvider),
    prefs: ref.read(sharedPreferencesProvider),
    settings: () => ref.read(settingsProvider),
  ),
);

/// Decides whether a fresh snapshot warrants a desktop notification, and fires
/// it. Each trigger is independently toggleable (Settings) and de-duplicated so
/// a single threshold crossing or reset notifies exactly once per window cycle.
class UsageNotifier {
  final FlutterLocalNotificationsPlugin _plugin;
  final SharedPreferences _prefs;
  final Settings Function() _settings;

  UsageNotifier({
    required FlutterLocalNotificationsPlugin plugin,
    required SharedPreferences prefs,
    required Settings Function() settings,
  }) : _plugin = plugin,
       _prefs = prefs,
       _settings = settings;

  // Stable ids so a repeat of the same kind replaces rather than stacks.
  static const _idCritSession = 1;
  static const _idCritWeekly = 2;
  static const _idUrgent = 3;
  static const _idReset = 4;

  static const _critThreshold = 90.0;

  /// A percentage drop this large between consecutive readings means the window
  /// reset rather than wobbled from parser jitter.
  static const _resetDrop = 15.0;

  /// Only nudge about "filling fast" when the projected fill is within this
  /// many minutes — far enough out it isn't urgent.
  static const _urgentWindowMin = 20;

  static const _details = NotificationDetails(
    macOS: DarwinNotificationDetails(),
  );

  /// Evaluates [next] against the previous in-memory snapshot and current
  /// settings, firing any warranted notifications. [prev] is null on the first
  /// load of the run, which suppresses the reset notification then.
  Future<void> evaluate({
    UsageSnapshot? prev,
    required UsageSnapshot next,
    Forecast? forecast,
    DateTime? now,
  }) async {
    if (next.stale) return; // offline readings aren't real movement
    final s = _settings();
    final at = now ?? DateTime.now();

    if (s.notifyReset &&
        prev != null &&
        prev.session.percent - next.session.percent >= _resetDrop) {
      await _show(_idReset, 'Session quota reset · ready to go');
    }

    if (s.notifyCritical) {
      await _maybeCrit(_idCritSession, 'crit.session', 'Session', next.session, at);
      await _maybeCrit(_idCritWeekly, 'crit.weekly', 'Weekly', next.weekly, at);
    }

    if (s.notifyUrgent && forecast?.full != null) {
      final eta = forecast!.full!;
      final mins = eta.difference(at).inMinutes;
      final resetsAt = next.session.resetsAt;
      final beforeReset = resetsAt == null || eta.isBefore(resetsAt);
      if (mins > 0 &&
          mins <= _urgentWindowMin &&
          beforeReset &&
          next.session.percent < _critThreshold &&
          await _arm('urgent.session', resetsAt)) {
        await _show(
          _idUrgent,
          'Session is filling fast · ${Fmt.inApprox(eta, now: at)}',
        );
      }
    }
  }

  Future<void> _maybeCrit(
    int id,
    String key,
    String name,
    UsageWindow window,
    DateTime at,
  ) async {
    if (window.percent < _critThreshold) return;
    if (!await _arm(key, window.resetsAt)) return;
    await _show(id, '$name at ${window.percent.round()}%${_resetClause(window, at)}');
  }

  /// "· resets in 22m" appended to a critical body, or empty when unknown.
  String _resetClause(UsageWindow window, DateTime at) {
    final r = Fmt.resets(window.resetsAt, now: at);
    if (r == null) return '';
    return ' · ${r[0].toLowerCase()}${r.substring(1)}';
  }

  /// Returns true the first time it's called for a given window cycle (keyed by
  /// [resetsAt]); false on repeats. The stored cycle id changes when the window
  /// resets, which re-arms the trigger for the next cycle automatically — and
  /// survives app restarts since it's persisted.
  Future<bool> _arm(String key, DateTime? resetsAt) async {
    final cycle = resetsAt?.toIso8601String() ?? 'none';
    final storeKey = 'notif.$key';
    if (_prefs.getString(storeKey) == cycle) return false;
    await _prefs.setString(storeKey, cycle);
    return true;
  }

  Future<void> _show(int id, String body) => _plugin.show(
    id: id,
    title: 'ClaudeBar',
    body: body,
    notificationDetails: _details,
  );
}
