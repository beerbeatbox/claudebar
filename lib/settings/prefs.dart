import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which window the menu-bar number reflects (spec §2 — user-switchable).
enum MenuBarMetric { session, weekly }

/// Persisted user settings (spec §10, Phase 2).
class Settings {
  /// Auto-refresh interval in minutes (presets: 1 / 2 / 5 / 15; default 5).
  final int refreshMinutes;
  final MenuBarMetric metric;
  final bool launchAtLogin;

  const Settings({
    this.refreshMinutes = 5,
    this.metric = MenuBarMetric.session,
    this.launchAtLogin = false,
  });

  Settings copyWith({int? refreshMinutes, MenuBarMetric? metric, bool? launchAtLogin}) {
    return Settings(
      refreshMinutes: refreshMinutes ?? this.refreshMinutes,
      metric: metric ?? this.metric,
      launchAtLogin: launchAtLogin ?? this.launchAtLogin,
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

class SettingsController extends Notifier<Settings> {
  @override
  Settings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return Settings(
      refreshMinutes: prefs.getInt(_kInterval) ?? 5,
      metric: MenuBarMetric.values[
          (prefs.getInt(_kMetric) ?? 0).clamp(0, MenuBarMetric.values.length - 1)],
      launchAtLogin: prefs.getBool(_kLaunch) ?? false,
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
}

final settingsProvider =
    NotifierProvider<SettingsController, Settings>(SettingsController.new);
