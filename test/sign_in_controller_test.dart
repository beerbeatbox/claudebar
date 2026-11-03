// The "Sign in…" flow end to end, minus the real CLI: a fake source stays
// signed out until a sign-in completes, and each sign-in waits on a completer
// the test resolves — so every outcome (success, failure, superseded,
// cancelled) can be driven deterministically.

import 'dart:async';

import 'package:claude_usage_bar/data/cli_usage_source.dart';
import 'package:claude_usage_bar/models/usage_error.dart';
import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/state/sign_in_controller.dart';
import 'package:claude_usage_bar/state/usage_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCli extends CliUsageSource {
  bool signedIn = false;
  int fetches = 0;
  int cancels = 0;
  final attempts = <Completer<SignInResult>>[];
  final kinds = <String>[];

  @override
  Future<CliUsageResult> fetch() async {
    fetches++;
    if (!signedIn) return const CliUsageResult.fail(UsageError.noCredentials);
    return CliUsageResult.ok(UsageSnapshot(
      session: const UsageWindow(percent: 35, label: 'Session · 5h'),
      weekly: const UsageWindow(percent: 28, label: 'Weekly · 7d'),
      plan: 'Max',
      fetchedAt: DateTime(2026, 11, 3, 12, 0),
    ));
  }

  Future<SignInResult> _start(String kind) {
    kinds.add(kind);
    final attempt = Completer<SignInResult>();
    attempts.add(attempt);
    return attempt.future;
  }

  @override
  Future<SignInResult> signIn() => _start('browser');

  @override
  Future<SignInResult> signInInTerminal() => _start('terminal');

  @override
  void cancelSignIn() {
    cancels++;
    for (final attempt in attempts) {
      if (!attempt.isCompleted) attempt.complete(SignInResult.cancelled);
    }
  }
}

/// Lets the microtask-started first refresh (and anything it chains) land.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ProviderContainer> _signedOutContainer(_FakeCli cli) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cliUsageSourceProvider.overrideWithValue(cli),
    ],
  );
  addTearDown(container.dispose);
  container.read(usageControllerProvider);
  await _settle();
  expect(container.read(usageControllerProvider).needsSignIn, isTrue);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a finished sign-in refreshes usage straight away', () async {
    final cli = _FakeCli();
    final container = await _signedOutContainer(cli);
    final controller = container.read(signInControllerProvider.notifier);

    final done = controller.signIn();
    expect(container.read(signInControllerProvider).phase, SignInPhase.browser);
    expect(cli.kinds, ['browser']);

    cli.signedIn = true;
    cli.attempts.single.complete(SignInResult.signedIn);
    await done;
    await _settle();

    final signIn = container.read(signInControllerProvider);
    expect(signIn.inProgress, isFalse);
    expect(signIn.error, isNull);
    final usage = container.read(usageControllerProvider);
    expect(cli.fetches, 2, reason: 'no waiting out the error backoff');
    expect(usage.error, isNull);
    expect(usage.snapshot?.session.percent, 35);
  });

  test('a failed sign-in keeps its reason for the popover', () async {
    final cli = _FakeCli();
    final container = await _signedOutContainer(cli);

    final done = container.read(signInControllerProvider.notifier).signIn();
    cli.attempts.single
        .complete(const SignInResult.failed('Sign-in didn’t finish: nope'));
    await done;

    final signIn = container.read(signInControllerProvider);
    expect(signIn.inProgress, isFalse);
    expect(signIn.error, 'Sign-in didn’t finish: nope');
    expect(cli.fetches, 1, reason: 'nothing to refresh after a failure');
  });

  test('switching to Terminal supersedes the browser attempt', () async {
    final cli = _FakeCli();
    final container = await _signedOutContainer(cli);
    final controller = container.read(signInControllerProvider.notifier);

    final browser = controller.signIn();
    final terminal = controller.signIn(terminal: true);
    expect(cli.kinds, ['browser', 'terminal']);

    // The abandoned browser attempt reports late; it must not clobber the
    // Terminal attempt's state.
    cli.attempts.first.complete(const SignInResult.failed('late'));
    await browser;
    final mid = container.read(signInControllerProvider);
    expect(mid.phase, SignInPhase.terminal);
    expect(mid.error, isNull);

    cli.signedIn = true;
    cli.attempts.last.complete(SignInResult.signedIn);
    await terminal;
    await _settle();
    expect(container.read(signInControllerProvider).inProgress, isFalse);
    expect(container.read(usageControllerProvider).snapshot, isNotNull);
  });

  test('cancel stops the attempt and resets the state', () async {
    final cli = _FakeCli();
    final container = await _signedOutContainer(cli);
    final controller = container.read(signInControllerProvider.notifier);

    final done = controller.signIn();
    controller.cancel();
    await done;

    final signIn = container.read(signInControllerProvider);
    expect(cli.cancels, greaterThanOrEqualTo(1));
    expect(signIn.inProgress, isFalse);
    expect(signIn.error, isNull);
    expect(container.read(usageControllerProvider).needsSignIn, isTrue);
  });

  test('a stale failure clears once usage reads again by another route',
      () async {
    final cli = _FakeCli();
    final container = await _signedOutContainer(cli);

    final done = container.read(signInControllerProvider.notifier).signIn();
    cli.attempts.single.complete(const SignInResult.failed('nope'));
    await done;
    expect(container.read(signInControllerProvider).error, 'nope');

    // Signed in from their own terminal; the next refresh picks it up.
    cli.signedIn = true;
    await container.read(usageControllerProvider.notifier).refresh();

    expect(container.read(usageControllerProvider).needsSignIn, isFalse);
    expect(container.read(signInControllerProvider).error, isNull);
  });
}
