import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Display version of an update Sparkle has found and is holding back under
/// gentle reminders (e.g. "1.5.8"), or null when there is none. The tray menu
/// surfaces it as an "Update Available (…)…" item.
class PendingUpdate extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? version) => state = version;
}

final pendingUpdateProvider =
    NotifierProvider<PendingUpdate, String?>(PendingUpdate.new);

/// Dart face of the native UpdaterChannel (Sparkle with gentle reminders).
///
/// Replaces the auto_updater plugin: its stock Sparkle setup could activate
/// this background app on Sparkle's own schedule (permission prompt, scheduled
/// update alerts), stealing focus from the app the user was typing in and
/// flashing the macOS input-source capsule at their caret. See UpdaterChannel
/// in macos/Runner/MainFlutterWindow.swift for the full story. On this side
/// nothing shows UI: scheduled finds only flip [pendingUpdateProvider], and
/// Sparkle's own windows appear solely on the user-initiated calls below.
class AppUpdater {
  AppUpdater._();

  static const _channel = MethodChannel('claudebar/updater');

  /// Routes native update events into [pendingUpdateProvider]. Call once from
  /// main(), before [start].
  static void init(ProviderContainer container) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'updateAvailable':
          container
              .read(pendingUpdateProvider.notifier)
              .set(call.arguments as String?);
        case 'updateSessionEnded':
          // Installed, or dismissed from the focused flow — either way the
          // menu item is stale; the next scheduled check re-announces if the
          // update is still pending.
          container.read(pendingUpdateProvider.notifier).set(null);
      }
      return null;
    });
  }

  /// Points Sparkle at the stable or beta appcast; consulted at check time.
  static Future<void> setFeedURL(String url) =>
      _channel.invokeMethod('setFeedURL', url);

  static Future<void> setScheduledCheckInterval(int seconds) =>
      _channel.invokeMethod('setScheduledCheckInterval', seconds);

  /// Starts Sparkle's scheduler. Call after the feed URL and interval are set.
  static Future<void> start() => _channel.invokeMethod('start');

  /// User-initiated check — Sparkle shows its UI in focus, as expected.
  static Future<void> checkForUpdates() =>
      _channel.invokeMethod('checkForUpdates');

  /// Brings the gently-announced pending update into focus (tray-menu click).
  /// Same native call as [checkForUpdates]: with a deferred update session
  /// pending, SPUUpdater routes it to the user driver's showUpdateInFocus
  /// instead of starting a new check.
  static Future<void> showPendingUpdate() =>
      _channel.invokeMethod('checkForUpdates');
}
