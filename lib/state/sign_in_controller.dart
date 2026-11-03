import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cli_usage_source.dart';
import 'usage_controller.dart';

/// Where a ClaudeBar-started sign-in currently stands.
enum SignInPhase {
  /// Nothing running.
  idle,

  /// `claude auth login` is running headless, waiting on the browser.
  browser,

  /// A Terminal window is running `claude auth login`.
  terminal,
}

class SignInState {
  final SignInPhase phase;

  /// Why the last attempt failed — shown until the next one starts, or until
  /// usage reads again (signed in some other way).
  final String? error;

  const SignInState({this.phase = SignInPhase.idle, this.error});

  bool get inProgress => phase != SignInPhase.idle;
}

/// Runs the popover's / tray menu's "Sign in…" for a signed-out Claude Code
/// CLI and, once it lands, hands straight back to [UsageController] for an
/// immediate refresh — click, approve in the browser, and the numbers return
/// without anything else to do.
///
/// Kept apart from [UsageState] on purpose: every refresh replaces that state
/// wholesale, and a periodic retry landing mid-sign-in must not wipe the
/// "waiting for your browser" state (or its Cancel button) off the popover.
class SignInController extends Notifier<SignInState> {
  /// Bumped per attempt (and on cancel), so a superseded attempt's late
  /// result can't overwrite the state of whatever replaced it.
  int _attempt = 0;

  @override
  SignInState build() {
    final source = ref.watch(cliUsageSourceProvider);
    // Never leave a headless `auth login` running past its owner.
    ref.onDispose(source.cancelSignIn);
    // Signed in some other way while a failure message sat here (the user's
    // own terminal, `/login` in a session): the message is moot once usage
    // reads again.
    ref.listen(usageControllerProvider.select((s) => s.needsSignIn),
        (was, now) {
      if (was == true && !now && !state.inProgress) {
        state = const SignInState();
      }
    });
    return const SignInState();
  }

  /// Starts a sign-in. By default the CLI's own browser flow runs headless;
  /// [terminal] opens a Terminal window running it instead — the fallback
  /// when the browser hand-off can't finish on its own. Starting one while
  /// another is running replaces it.
  Future<void> signIn({bool terminal = false}) async {
    final attempt = ++_attempt;
    state = SignInState(
      phase: terminal ? SignInPhase.terminal : SignInPhase.browser,
    );
    final source = ref.read(cliUsageSourceProvider);
    final result =
        terminal ? await source.signInInTerminal() : await source.signIn();
    if (!ref.mounted || attempt != _attempt) return;
    switch (result.outcome) {
      case SignInOutcome.signedIn:
        state = const SignInState();
        ref.read(usageControllerProvider.notifier).refreshAfterSignIn();
      case SignInOutcome.cancelled:
        state = const SignInState();
      case SignInOutcome.failed:
        state = SignInState(error: result.message);
    }
  }

  /// Abandons the sign-in in flight (a headless one is killed; a Terminal
  /// window is left for the user to close).
  void cancel() {
    _attempt++;
    ref.read(cliUsageSourceProvider).cancelSignIn();
    state = const SignInState();
  }
}

final signInControllerProvider =
    NotifierProvider<SignInController, SignInState>(SignInController.new);
