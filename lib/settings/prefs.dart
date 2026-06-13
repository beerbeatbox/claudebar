import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which window the menu-bar number reflects (spec §2 — user-switchable).
enum MenuBarMetric { session, weekly }

/// Persisted user settings (spec §10, Phase 2).
class Settings {
  /// Auto-refresh interval in minutes (presets: 2 / 5 / 15; default 5). 1m was
  /// dropped — the usage endpoint rate-limits too hard to poll that often.
  final int refreshMinutes;
  final MenuBarMetric metric;
  final bool launchAtLogin;

  /// Notify when a window crosses 90% used.
  final bool notifyCritical;

  /// Notify when the burn rate projects the session filling within minutes.
  final bool notifyUrgent;

  /// Notify when the session quota resets and is ready again.
  final bool notifyReset;

  const Settings({
    this.refreshMinutes = 5,
    this.metric = MenuBarMetric.session,
    this.launchAtLogin = false,
    this.notifyCritical = true,
    this.notifyUrgent = true,
    this.notifyReset = true,
  });

  Settings copyWith({
    int? refreshMinutes,
    MenuBarMetric? metric,
    bool? launchAtLogin,
    bool? notifyCritical,
    bool? notifyUrgent,
    bool? notifyReset,
  }) {
    return Settings(
      refreshMinutes: refreshMinutes ?? this.refreshMinutes,
      metric: metric ?? this.metric,
      launchAtLogin: launchAtLogin ?? this.launchAtLogin,
      notifyCritical: notifyCritical ?? this.notifyCritical,
      notifyUrgent: notifyUrgent ?? this.notifyUrgent,
      notifyReset: notifyReset ?? this.notifyReset,
    );
  }
}

/// Overridden with the resolved instance in `main()` so the rest of the app
/// reads it synchronously.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not overridden'),
);

const _kInterval = 'refreshMinutes';
const _kMetric = 'menuBarMetric';
const _kLaunch = 'launchAtLogin';
const _kNotifyCritical = 'notifyCritical';
const _kNotifyUrgent = 'notifyUrgent';
const _kNotifyReset = 'notifyReset';

class SettingsController extends Notifier<Settings> {
  @override
  Settings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    // Migrate anyone who had the now-removed 1m preset up to the 2m floor.
    final storedInterval = prefs.getInt(_kInterval) ?? 5;
    return Settings(
      refreshMinutes: storedInterval < 2 ? 2 : storedInterval,
      metric: MenuBarMetric.values[
          (prefs.getInt(_kMetric) ?? 0).clamp(0, MenuBarMetric.values.length - 1)],
      launchAtLogin: prefs.getBool(_kLaunch) ?? false,
      notifyCritical: prefs.getBool(_kNotifyCritical) ?? true,
      notifyUrgent: prefs.getBool(_kNotifyUrgent) ?? true,
      notifyReset: prefs.getBool(_kNotifyReset) ?? true,
    );
  }

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  Future<void> setRefreshMinutes(int minutes) async {
    state = state.copyWith(refreshMinutes: minutes);
    await _prefs.setInt(_kInterval, minutes);
  }

  Future<void> setMetric(MenuBarMetric metric) async {
    state = state.copyWith(metric: metric);
    await _prefs.setInt(_kMetric, metric.index);
  }

  Future<void> setLaunchAtLogin(bool value) async {
    state = state.copyWith(launchAtLogin: value);
    await _prefs.setBool(_kLaunch, value);
    // launchAtStartup is set up in main() before this runs.
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }

  Future<void> setNotifyCritical(bool value) async {
    state = state.copyWith(notifyCritical: value);
    await _prefs.setBool(_kNotifyCritical, value);
  }

  Future<void> setNotifyUrgent(bool value) async {
    state = state.copyWith(notifyUrgent: value);
    await _prefs.setBool(_kNotifyUrgent, value);
  }

  Future<void> setNotifyReset(bool value) async {
    state = state.copyWith(notifyReset: value);
    await _prefs.setBool(_kNotifyReset, value);
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, Settings>(SettingsController.new);
