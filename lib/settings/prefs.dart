import 'package:auto_updater/auto_updater.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which window the menu-bar number reflects (spec §2 — user-switchable).
enum MenuBarMetric { session, weekly }

/// SharedPreferences key for the beta opt-in; read in `main()` to pick the
/// update feed before the first scheduled check, so it must match the key the
/// SettingsController writes.
const String kBetaUpdatesPref = 'betaUpdates';

/// Sparkle appcast feeds (served from GitHub Pages). Beta testers track a
/// separate feed that also carries every stable release, so opting in never
/// holds them back from a stable update; opting out returns them to the
/// stable-only feed.
const String stableAppcastUrl =
    'https://beerbeatbox.github.io/claudebar/appcast.xml';
const String betaAppcastUrl =
    'https://beerbeatbox.github.io/claudebar/appcast-beta.xml';

/// The feed URL for the user's current channel choice.
String appcastUrlFor(bool beta) => beta ? betaAppcastUrl : stableAppcastUrl;

/// Persisted user settings (spec §10, Phase 2).
class Settings {
  /// Auto-refresh interval in minutes (presets: 2 / 5 / 15; default 5). 1m was
  /// dropped — the usage endpoint rate-limits too hard to poll that often.
  final int refreshMinutes;
  final MenuBarMetric metric;
  final bool launchAtLogin;

  /// Opt-in to pre-release builds: switches the Sparkle feed to the beta
  /// appcast. Off by default so existing users stay on stable.
  final bool betaUpdates;

  const Settings({
    this.refreshMinutes = 5,
    this.metric = MenuBarMetric.session,
    this.launchAtLogin = false,
    this.betaUpdates = false,
  });

  Settings copyWith({
    int? refreshMinutes,
    MenuBarMetric? metric,
    bool? launchAtLogin,
    bool? betaUpdates,
  }) {
    return Settings(
      refreshMinutes: refreshMinutes ?? this.refreshMinutes,
      metric: metric ?? this.metric,
      launchAtLogin: launchAtLogin ?? this.launchAtLogin,
      betaUpdates: betaUpdates ?? this.betaUpdates,
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
const _kBeta = kBetaUpdatesPref;

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
      betaUpdates: prefs.getBool(_kBeta) ?? false,
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

  /// Switch the Sparkle update feed between the stable and beta appcasts. Takes
  /// effect on the next check (scheduled or the tray's "Check for Updates…");
  /// main() applies the persisted choice at launch.
  Future<void> setBetaUpdates(bool value) async {
    state = state.copyWith(betaUpdates: value);
    await _prefs.setBool(_kBeta, value);
    await autoUpdater.setFeedURL(appcastUrlFor(value));
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, Settings>(SettingsController.new);
