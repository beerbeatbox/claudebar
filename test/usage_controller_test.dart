// Regression test: changing the refresh interval must NOT blank the usage
// state. UsageController.build watches refreshMinutes, so an interval change
// re-runs build — which used to return loading() (snapshot = null), making
// the menu-bar title flash "–" until the next fetch landed.

import 'package:claude_usage_bar/data/cli_usage_source.dart';
import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/state/usage_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves one canned snapshot without spawning the real CLI.
class _FakeCliSource extends CliUsageSource {
  int calls = 0;

  @override
  Future<CliUsageResult> fetch() async {
    calls++;
    return CliUsageResult.ok(UsageSnapshot(
      session: const UsageWindow(percent: 35, label: 'Session · 5h'),
      weekly: const UsageWindow(percent: 28, label: 'Weekly · 7d'),
      plan: 'Max',
      fetchedAt: DateTime(2026, 6, 12, 22, 0),
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('changing the refresh interval keeps the current snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cli = _FakeCliSource();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        cliUsageSourceProvider.overrideWithValue(cli),
      ],
    );
    addTearDown(container.dispose);

    // First build kicks the initial refresh; let the microtask + fetch land.
    container.read(usageControllerProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final before = container.read(usageControllerProvider);
    expect(before.snapshot, isNotNull, reason: 'initial fetch should land');

    await container.read(settingsProvider.notifier).setRefreshMinutes(15);

    final after = container.read(usageControllerProvider);
    expect(after.snapshot, same(before.snapshot),
        reason: 'interval change must not reset state to loading');
    expect(after.loading, isFalse);
    expect(cli.calls, 1,
        reason: 'interval change must not trigger an extra fetch');
  });
}
