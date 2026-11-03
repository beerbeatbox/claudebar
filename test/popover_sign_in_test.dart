// The popover's signed-out card: "Sign in…" starts the sign-in, the card
// switches to "Waiting for sign-in…" with a Cancel, and once the sign-in
// lands the meters come straight back — no Refresh click needed.

import 'dart:async';

import 'package:claude_usage_bar/data/cli_usage_source.dart';
import 'package:claude_usage_bar/models/usage_error.dart';
import 'package:claude_usage_bar/models/usage_snapshot.dart';
import 'package:claude_usage_bar/models/usage_window.dart';
import 'package:claude_usage_bar/settings/prefs.dart';
import 'package:claude_usage_bar/state/usage_controller.dart';
import 'package:claude_usage_bar/ui/popover_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCli extends CliUsageSource {
  bool signedIn = false;
  Completer<SignInResult>? attempt;
  String? lastKind;

  @override
  Future<CliUsageResult> fetch() async {
    if (!signedIn) return const CliUsageResult.fail(UsageError.noCredentials);
    return CliUsageResult.ok(UsageSnapshot(
      session: const UsageWindow(percent: 35, label: 'Session · 5h'),
      weekly: const UsageWindow(percent: 28, label: 'Weekly · 7d'),
      plan: 'Max',
      fetchedAt: DateTime(2026, 11, 3, 12, 0),
    ));
  }

  Future<SignInResult> _start(String kind) {
    lastKind = kind;
    return (attempt = Completer<SignInResult>()).future;
  }

  @override
  Future<SignInResult> signIn() => _start('browser');

  @override
  Future<SignInResult> signInInTerminal() => _start('terminal');

  @override
  void cancelSignIn() {
    final a = attempt;
    if (a != null && !a.isCompleted) a.complete(SignInResult.cancelled);
  }
}

Future<_FakeCli> _pumpPopover(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final cli = _FakeCli();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        cliUsageSourceProvider.overrideWithValue(cli),
      ],
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
  await tester.pump(); // let the first (signed-out) probe land
  await tester.pump(const Duration(milliseconds: 50));
  return cli;
}

void main() {
  testWidgets('Sign in… signs in and brings the meters back', (tester) async {
    final cli = await _pumpPopover(tester);

    expect(find.text('Claude Code is signed out'), findsOneWidget);
    expect(find.text('Sign in…'), findsOneWidget);
    expect(find.text('Use Terminal'), findsOneWidget);

    await tester.tap(find.text('Sign in…'));
    await tester.pump();
    expect(cli.lastKind, 'browser');
    expect(find.text('Waiting for sign-in…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    cli.signedIn = true;
    cli.attempt!.complete(SignInResult.signedIn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Sign in…'), findsNothing);
    expect(find.text('Waiting for sign-in…'), findsNothing);
    expect(find.text('SESSION · 5H'), findsOneWidget);
    expect(find.text('35%'), findsOneWidget);

    // Dispose the tree so the controllers' timers get cancelled.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed sign-in offers Try again and the Terminal route',
      (tester) async {
    final cli = await _pumpPopover(tester);

    await tester.tap(find.text('Sign in…'));
    await tester.pump();
    cli.attempt!.complete(
        const SignInResult.failed('Sign-in didn’t finish: access denied'));
    await tester.pump();

    expect(find.text('Sign-in didn’t finish: access denied'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Use Terminal'));
    await tester.pump();
    expect(cli.lastKind, 'terminal');
    expect(find.textContaining('A Terminal window is open'), findsOneWidget);
    expect(find.text('Use Terminal'), findsNothing,
        reason: 'already the Terminal route');

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Sign in…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // A page that asks for a pasted code is a dead end for the headless flow;
  // the waiting card must offer the way out without a Cancel first.
  testWidgets('a waiting browser sign-in can hand over to Terminal',
      (tester) async {
    final cli = await _pumpPopover(tester);

    await tester.tap(find.text('Sign in…'));
    await tester.pump();
    expect(find.textContaining('paste a code'), findsOneWidget);

    await tester.tap(find.text('Use Terminal'));
    await tester.pump();
    expect(cli.lastKind, 'terminal');
    expect(find.textContaining('A Terminal window is open'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
