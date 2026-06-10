import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app/measure_size.dart';
import 'app/popover_window.dart';
import 'app/tray_controller.dart';
import 'settings/prefs.dart';
import 'state/usage_controller.dart';
import 'ui/popover_panel.dart';

late final PopoverWindow _popover;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Register the login-item handle so the Settings toggle can enable/disable
  // "Open at login" (spec §10, Phase 2).
  launchAtStartup.setup(
    appName: 'ClaudeBar',
    appPath: Platform.resolvedExecutable,
  );

  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );

  _popover = PopoverWindow();
  await _popover.init();

  final tray = TrayController(container: container, popover: _popover);
  await tray.init();

  // Eagerly create the usage controller so the tray starts refreshing even
  // before the popover is ever opened.
  container.read(usageControllerProvider);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ClaudeBarApp(),
    ),
  );
}

/// Quits the whole app (used by the popover's Settings → Quit).
Future<void> quitApp() async {
  await trayManager.destroy();
  exit(0);
}

class ClaudeBarApp extends StatelessWidget {
  const ClaudeBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
        fontFamily: '.AppleSystemUIFont',
      ),
      home: Material(
        type: MaterialType.transparency,
        child: MeasureSize(
          onChange: (size) => _popover.setContentHeight(size.height),
          child: Popover(onQuit: quitApp, arrowFromRight: _popover.arrowFromRight),
        ),
      ),
    );
  }
}
