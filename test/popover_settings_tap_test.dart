// Regression test: tapping the settings gear must switch the popover to the
// SettingsPanel. The usage controller's CLI source is inert under
// flutter_tester (FLUTTER_TEST guard), so no real `claude` is spawned.

import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/ui/popover_panel.dart';
import 'package:claude_usage_bar/ui/settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('tapping the gear opens SettingsPanel', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: Material(
            type: MaterialType.transparency,
            child: Popover(
              onQuit: () {},
              arrowFromRight: ValueNotifier<double>(70),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // let the fake snapshot land
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(SettingsPanel), findsOneWidget);

    // Dispose the tree so the controller's periodic timers get cancelled.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
