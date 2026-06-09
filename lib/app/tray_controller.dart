import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';

import '../models/usage_window.dart';
import '../settings/prefs.dart';
import '../state/usage_controller.dart';
import '../ui/format.dart';
import 'popover_window.dart';

/// Drives the menu-bar status item: the live `%` title plus a context menu,
/// reacting to changes in the shared [UsageController] (spec §4, Phase 1).
class TrayController with TrayListener {
  TrayController({required this.container, required this.popover});

  final ProviderContainer container;
  final PopoverWindow popover;

  Future<void> init() async {
    trayManager.addListener(this);
    await trayManager.setTitle('--%');
    await _rebuild();

    // Re-render whenever usage or the chosen metric changes.
    container.listen(usageControllerProvider, (_, __) => _rebuild(), fireImmediately: false);
    container.listen(settingsProvider, (_, __) => _rebuild(), fireImmediately: false);
  }

  Future<void> _rebuild() async {
    final state = container.read(usageControllerProvider);
    final settings = container.read(settingsProvider);
    await trayManager.setTitle(_title(state, settings.metric));
    await trayManager.setContextMenu(_menu(state));
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
