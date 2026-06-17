import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import '../models/usage_window.dart';
import '../settings/prefs.dart';
import '../state/usage_controller.dart';
import '../ui/format.dart';
import '../ui/tokens.dart';
import 'popover_window.dart';
import 'tray_glyph.dart';

/// Drives the menu-bar status item: a ring gauge for the usage % with the
/// reset countdown as its title, plus a context menu, reacting to changes in
/// the shared [UsageController] (spec §4, Phase 1).
class TrayController with TrayListener {
  TrayController({required this.container, required this.popover});

  final ProviderContainer container;
  final PopoverWindow popover;

  /// tray_manager only creates the NSStatusItem inside `setIcon`; the rest of
  /// the API (setTitle/setContextMenu) is a silent no-op until that happens.
  /// We drive the icon directly through the channel so we can hand it a
  /// runtime-rendered glyph (base64) instead of a bundled asset.
  static const MethodChannel _trayChannel = MethodChannel('tray_manager');

  /// Native pushes 'recover' here when macOS is liable to have dropped the
  /// status item: a display-topology change (external monitor connect/disconnect,
  /// dock/undock, resolution change) OR sleep/wake. macOS 26 routinely detaches
  /// menu-bar items on those events and leaves them invisible until the status
  /// item is recreated — see the sibling app CodexBar's issues #1077/#1088 for
  /// the same failure mode.
  static const MethodChannel _recoveryChannel = MethodChannel('claudebar/tray');

  Timer? _countdownTimer;

  /// Coalesces a burst of display-change events into a single recovery, once
  /// the topology has settled.
  Timer? _recoverDebounce;

  /// Guards against overlapping recoveries (a display burst and the periodic
  /// self-heal could otherwise run at once).
  bool _recovering = false;

  Future<void> init() async {
    trayManager.addListener(this);
    _recoveryChannel.setMethodCallHandler(_onRecoveryCall);
    await _rebuild();

    // Re-render whenever usage or the chosen metric changes.
    container.listen(usageControllerProvider, (_, __) => _rebuild(), fireImmediately: false);
    container.listen(settingsProvider, (_, __) => _rebuild(), fireImmediately: false);

    // The title carries a minute-granular reset countdown, so tick it along
    // between refreshes (design mockup variant G: ring + "2h14m"). The tick
    // also self-heals the status item if macOS has silently dropped it.
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  Future<void> _rebuild() async {
    final state = container.read(usageControllerProvider);
    final settings = container.read(settingsProvider);
    await _updateGlyph(state, settings.metric);
    await trayManager.setTitle(_title(state, settings.metric));
    await trayManager.setContextMenu(_menu(state));
  }

  /// Minute tick: keep the status item alive, then refresh its countdown. If
  /// macOS has silently dropped the item (a Control Center eviction when the
  /// menu bar is full, with no display event to catch), recreate it instead.
  Future<void> _tick() async {
    if (!_recovering && await _trayMissing()) {
      await _recover('self-heal');
    } else {
      await _rebuild();
    }
  }

  Future<dynamic> _onRecoveryCall(MethodCall call) async {
    if (call.method == 'recover') {
      // The system is usually mid-flux for a moment after the first event (the
      // topology settling, or the menu bar rebuilding after wake); wait for it
      // to settle, coalescing the burst into one recovery. We recover
      // unconditionally rather than checking _trayMissing first: when macOS
      // force-hides the item it keeps the bounds valid (isVisible stays true),
      // so the only reliable cure is to recreate it on every such event.
      _recoverDebounce?.cancel();
      _recoverDebounce = Timer(
        const Duration(milliseconds: 800),
        () => _recover('display/wake'),
      );
    }
    return null;
  }

  /// Rebuilds the status item from scratch. Re-pushing the icon is not enough
  /// once macOS has detached the item from a screen, so tear it down and
  /// recreate it (setIcon re-creates the NSStatusItem), then verify it actually
  /// landed — macOS can still leave it detached, so retry a few times with
  /// backoff (mirrors CodexBar v0.28.0's settle-and-retry recovery).
  Future<void> _recover(String reason) async {
    if (_recovering) return;
    _recovering = true;
    try {
      for (var attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) {
          await Future.delayed(Duration(milliseconds: 500 * attempt));
        }
        try {
          await trayManager.destroy();
          await _rebuild();
        } catch (e) {
          debugPrint('[ClaudeBar] tray recovery ($reason) attempt $attempt: $e');
          continue;
        }
        if (!await _trayMissing()) {
          if (attempt > 0) {
            debugPrint('[ClaudeBar] tray recovered ($reason) on attempt $attempt');
          }
          return;
        }
      }
      debugPrint('[ClaudeBar] tray still missing after recovery ($reason)');
    } finally {
      _recovering = false;
    }
  }

  /// True when the status item has no on-screen presence — no bounds, or a
  /// collapsed (~zero) width — which is how a detached/evicted item reports.
  Future<bool> _trayMissing() async {
    try {
      final bounds = await trayManager.getBounds();
      return bounds == null || bounds.width <= 1;
    } catch (_) {
      return true;
    }
  }

  /// Draws the ring gauge for the selected window and installs it as the
  /// status-item image (design mockup variant G — "Ring + countdown").
  Future<void> _updateGlyph(UsageState state, MenuBarMetric metric) async {
    final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    final t = dark ? ClaudeTokens.dark : ClaudeTokens.light;
    final snapshot = state.snapshot;
    final stale = snapshot?.stale ?? false;
    final window =
        metric == MenuBarMetric.weekly ? snapshot?.weekly : snapshot?.session;
    final percent = window?.percent ?? 0;

    final png = await renderTrayGlyph(
      percent: percent,
      color: stale ? t.text3 : levelColor(percent, t),
      // The menu bar sits over the wallpaper, so the track needs a touch more
      // contrast than the in-popover token.
      track: dark ? const Color(0x4DFFFFFF) : const Color(0x33000000),
    );

    await _trayChannel.invokeMethod('setIcon', <String, dynamic>{
      'id': 'glyph',
      'base64Icon': base64Encode(png),
      'isTemplate': false,
      'iconPosition': 'left',
      'iconSize': 18,
      'iconPath': '',
    });
  }

  String _title(UsageState state, MenuBarMetric metric) {
    final snapshot = state.snapshot;
    if (snapshot != null) {
      final window = metric == MenuBarMetric.weekly ? snapshot.weekly : snapshot.session;
      // The % lives in the ring, so the title carries just the countdown
      // (variant G). A fresh window has no reset clock yet (it starts on the
      // first request), so show "Ready" instead of a bare "0%"; fall back to
      // the % for the odd case of usage without a parsed reset time.
      final countdown = Fmt.countdownShort(window.resetsAt);
      if (countdown != null) return countdown;
      return window.percent == 0 ? 'Ready' : Fmt.pct(window.percent);
    }
    if (state.error != null) return state.error!.menuBarLabel;
    return '--%';
  }

  Menu _menu(UsageState state) {
    final items = <MenuItem>[];
    final snapshot = state.snapshot;

    if (snapshot != null) {
      items.add(_readonly(_windowLine(snapshot.session)));
      items.add(_readonly(_windowLine(snapshot.weekly)));
      if (snapshot.opus != null) items.add(_readonly(_windowLine(snapshot.opus!)));
      if (snapshot.sonnet != null) items.add(_readonly(_windowLine(snapshot.sonnet!)));
      items.add(MenuItem.separator());
      items.add(_readonly('Plan: ${snapshot.plan}'));
      if (snapshot.stale) {
        final reason = state.error?.staleReason ?? 'Offline';
        items.add(_readonly('$reason — last sync ${Fmt.updated(snapshot.fetchedAt).substring(8)}'));
      }
    } else if (state.error != null) {
      items.add(_readonly(state.error!.title));
    } else {
      items.add(_readonly('Loading…'));
    }

    items.add(MenuItem.separator());
    items.add(MenuItem(key: 'open', label: 'Open ClaudeBar'));
    items.add(MenuItem(key: 'refresh', label: 'Refresh'));
    items.add(MenuItem(key: 'check-updates', label: 'Check for Updates…'));
    items.add(MenuItem.separator());
    items.add(MenuItem(key: 'quit', label: 'Quit ClaudeBar'));

    return Menu(items: items);
  }

  String _windowLine(UsageWindow w) {
    final reset = Fmt.resets(w.resetsAt);
    final base = '${w.label}: ${Fmt.pct(w.percent)}';
    return reset == null ? base : '$base · ${reset.toLowerCase()}';
  }

  MenuItem _readonly(String label) => MenuItem(label: label, disabled: true);

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() => popover.toggle();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        popover.show();
        break;
      case 'refresh':
        container.read(usageControllerProvider.notifier).refresh();
        break;
      case 'check-updates':
        // User-initiated: Sparkle activates the app so its dialog surfaces even
        // though ClaudeBar is an LSUIElement (menu-bar) app. setFeedURL was set
        // once in main(); calling checkForUpdates() before that would no-op.
        autoUpdater.checkForUpdates();
        break;
      case 'quit':
        _quit();
        break;
    }
  }

  Future<void> _quit() async {
    _countdownTimer?.cancel();
    _recoverDebounce?.cancel();
    await trayManager.destroy();
    exit(0);
  }
}
