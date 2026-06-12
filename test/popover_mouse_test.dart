// Mimics a real desktop interaction on the footer gear: mouse moves in
// (hover), presses, releases — instead of WidgetTester.tap's instant down/up.

import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/state/usage_controller.dart';
import 'package:claude_usage_bar/ui/popover_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUsageController extends UsageController {
  @override
  UsageState build() {
    final now = DateTime.utc(2026, 6, 12, 12);
    return UsageState(
      snapshot: UsageSnapshot(
        session: UsageWindow(
          percent: 42,
          resetsAt: now.add(const Duration(hours: 3)),
          label: 'Session',
        ),
        weekly: UsageWindow(
          percent: 67,
          resetsAt: now.add(const Duration(days: 4)),
          label: 'Weekly',
        ),
        opus: const UsageWindow(percent: 18, label: 'Opus · weekly'),
        sonnet: const UsageWindow(percent: 55, label: 'Sonnet · weekly'),
        plan: 'Max',
        fetchedAt: now,
      ),
    );
  }
}

void main() {
  testWidgets('hover then click on the gear opens settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    tester.view.physicalSize = const Size(380, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          usageControllerProvider.overrideWith(_FakeUsageController.new),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
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
    await tester.pump();

    final gearCenter = tester.getCenter(find.byIcon(Icons.settings_outlined));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    // Hover in (fires MouseRegion.onEnter → setState), then press and hold a
    // realistic 80ms, then release.
    await mouse.moveTo(gearCenter);
    await tester.pump();
    await mouse.down(gearCenter);
    await tester.pump(const Duration(milliseconds: 80));
    await mouse.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Settings'), findsOneWidget);
  });
}
