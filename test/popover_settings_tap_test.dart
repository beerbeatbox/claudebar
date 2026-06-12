// Repro for "settings button in the popover does nothing": pumps the real
// Popover widget and taps the gear in the footer.

import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/state/usage_controller.dart';
import 'package:claude_usage_bar/ui/popover_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves a fixed snapshot and skips the real controller's timers, keychain
/// read, and network fetch.
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
  testWidgets('tapping the footer gear switches to the settings view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

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

    expect(find.text('ClaudeBar'), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    // Flush _FootBtn's 130ms pressed-visual timer so it doesn't trip the
    // pending-timer invariant at teardown.
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Settings'), findsOneWidget,
        reason: 'the settings view should replace the usage view');
  });
}
