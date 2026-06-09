import 'dart:convert';
import 'dart:io';

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

/// Drives the menu-bar status item: the live `%` title plus a context menu,
/// reacting to changes in the shared [UsageController] (spec §4, Phase 1).
class TrayController with TrayListener {
  TrayController({required this.container, required this.popover});

  final ProviderContainer container;
  final PopoverWindow popover;

  /// tray_manager only creates the NSStatusItem inside `setIcon`; the rest of
  /// the API (setTitle/setContextMenu) is a silent no-op until that happens.
  /// We drive the icon directly through the channel so we can hand it a
  /// runtime-rendered glyph (base64) instead of a bundled asset.
  static const MethodChannel _trayChannel = MethodChannel('tray_manager');

  Future<void> init() async {
    trayManager.addListener(this);
    await _rebuild();

    // Re-render whenever usage or the chosen metric changes.
    container.listen(usageControllerProvider, (_, __) => _rebuild(), fireImmediately: false);
    container.listen(settingsProvider, (_, __) => _rebuild(), fireImmediately: false);
  }

  Future<void> _rebuild() async {
    final state = container.read(usageControllerProvider);
    final settings = container.read(settingsProvider);
    await _updateGlyph(state);
    await trayManager.setTitle(_title(state, settings.metric));
    await trayManager.setContextMenu(_menu(state));
  }

  /// Draws the two-bar meter glyph for the current usage and installs it as the
  /// status-item image (design reference §"The status item").
  Future<void> _updateGlyph(UsageState state) async {
    final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    final t = dark ? ClaudeTokens.dark : ClaudeTokens.light;
    final snapshot = state.snapshot;
    final stale = snapshot?.stale ?? false;
    final session = snapshot?.session.percent ?? 0;
    final weekly = snapshot?.weekly.percent ?? 0;

    final png = await renderTrayGlyph(
      sessionPercent: session,
      weeklyPercent: weekly,
      sessionColor: stale ? t.text3 : levelColor(session, t),
      weeklyColor: stale ? t.text3 : t.accent,
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
      return Fmt.pct(window.percent);
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
      if (snapshot.stale) items.add(_readonly('Offline — last sync ${Fmt.updated(snapshot.fetchedAt).substring(8)}'));
    } else if (state.error != null) {
      items.add(_readonly(state.error!.title));
    } else {
      items.add(_readonly('Loading…'));
    }

    items.add(MenuItem.separator());
    items.add(MenuItem(key: 'open', label: 'Open ClaudeBar'));
    items.add(MenuItem(key: 'refresh', label: 'Refresh'));
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
      case 'quit':
        _quit();
        break;
    }
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    exit(0);
  }
}
