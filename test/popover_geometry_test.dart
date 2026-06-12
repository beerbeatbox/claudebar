// Documents the silent-failure mode behind "the settings gear does nothing":
// Flutter's hit-test region is the window-sized RenderView, so whenever the
// native window height lags the content's natural height (PopoverWindow
// .setContentHeight failing or being skipped), taps on the footer gear are
// dropped without any error — the popover just sits there.

import 'package:claude_usage_bar/app/measure_size.dart';
import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/state/usage_controller.dart';
import 'package:claude_usage_bar/ui/popover_panel.dart';
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
  testWidgets(
      'gear taps are silently dropped while the window is shorter than content',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    // Match the real popover window: 380 wide, 360 tall before any
    // setContentHeight lands.
    tester.view.physicalSize = const Size(380, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final reported = <double>[];

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
            child: MeasureSize(
              onChange: (size) => reported.add(size.height),
              child: Popover(
                onQuit: () {},
                arrowFromRight: ValueNotifier<double>(70),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The full usage view wants ~499pt; the gear lays out below the 360pt
    // hit-test boundary even though the same Dart code passes when the
    // window matches the content (see popover_settings_tap_test.dart).
    expect(reported, isNotEmpty);
    expect(reported.last, greaterThan(360));

    final gear = find.byIcon(Icons.settings_outlined);
    expect(gear, findsOneWidget);
    expect(tester.getCenter(gear).dy, greaterThan(360));

    // The tap misses (flutter_test prints a "tap() missed" warning) and the
    // popover silently stays on the usage view — the reported symptom.
    await tester.tap(gear, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Settings'), findsNothing);
    expect(find.text('ClaudeBar'), findsOneWidget);
  });
}
