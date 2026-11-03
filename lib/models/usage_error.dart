/// The distinct failure modes ClaudeBar surfaces, each mapped to a clear
/// user-facing message and menu-bar label (spec §11).
///
/// All usage flows through the `claude` CLI, so the kinds mirror the ways a
/// CLI probe can fail — classified by CliUsageSource so each one gets the
/// right UX instead of a silent fallback that would mask the cause.
enum UsageErrorKind {
  /// The `claude` binary couldn't be found on this machine.
  cliMissing,

  /// The CLI is installed but isn't signed in — never was, was signed out,
  /// or its login expired (the CLI wipes a token it can no longer refresh,
  /// after which it reads as signed out). Claude Desktop signs in on its own,
  /// so the desktop app can look perfectly healthy meanwhile — which is why
  /// this state gets a loud "Sign in" and a one-click fix rather than a grey
  /// stale reading.
  noCredentials,

  /// The CLI ran but couldn't reach Anthropic (machine offline, or the API
  /// is unreachable).
  network,

  /// The CLI answered fine but its `/usage` reply carried no usage lines —
  /// just the preamble. In print mode the probe frequently returns before the
  /// numbers are fetched (`duration_api_ms: 0`), so this is the common,
  /// transient empty reply — NOT an outage and NOT a format change. Kept
  /// distinct so the UI says "no fresh reading" instead of lying "Offline".
  noData,

  /// The CLI replied, we're online and signed in — but the `/usage` output
  /// didn't match the shape this version of ClaudeBar understands. Usually
  /// means a Claude Code update changed the wording; fail loud so it gets
  /// noticed and fixed, rather than degrading silently.
  parseFailed,

  /// Anything we didn't anticipate.
  unknown,
}

class UsageError {
  final UsageErrorKind kind;
  final String message;

  const UsageError(this.kind, this.message);

  /// True when the fix is signing Claude Code back in — the state the popover
  /// and the tray menu offer "Sign in…" for.
  bool get needsSignIn => kind == UsageErrorKind.noCredentials;

  /// Short text for the menu-bar status item.
  String get menuBarLabel {
    switch (kind) {
      case UsageErrorKind.cliMissing:
        return 'No CLI';
      case UsageErrorKind.noCredentials:
        return 'Sign in';
      case UsageErrorKind.network:
      case UsageErrorKind.noData:
      case UsageErrorKind.parseFailed:
      case UsageErrorKind.unknown:
        return '--%';
    }
  }

  /// Short reason phrase for the row above a kept-but-stale snapshot, e.g.
  /// "Offline" → "Offline — showing last sync". Names the *actual* cause so a
  /// transient empty reply or a parse failure isn't mislabeled as "Offline".
  String get staleReason {
    switch (kind) {
      case UsageErrorKind.cliMissing:
        return 'CLI not found';
      case UsageErrorKind.noCredentials:
        return 'Signed out';
      case UsageErrorKind.network:
        return 'Offline';
      case UsageErrorKind.noData:
        return 'No fresh reading';
      case UsageErrorKind.parseFailed:
        return 'Couldn’t read usage';
      case UsageErrorKind.unknown:
        return 'Not updating';
    }
  }

  /// Heading + body for the popover status state.
  String get title {
    switch (kind) {
      case UsageErrorKind.cliMissing:
        return 'Claude Code not found';
      case UsageErrorKind.noCredentials:
        return 'Claude Code is signed out';
      case UsageErrorKind.network:
        return 'Can’t reach Anthropic';
      case UsageErrorKind.noData:
        return 'Usage data unavailable';
      case UsageErrorKind.parseFailed:
        return 'Update ClaudeBar?';
      case UsageErrorKind.unknown:
        return 'Something went wrong';
    }
  }

  static const cliMissing = UsageError(
    UsageErrorKind.cliMissing,
    'ClaudeBar reads usage from the claude CLI, which wasn’t found on this Mac. Install Claude Code and sign in, then right-click the menu-bar icon → Refresh.',
  );

  static const noCredentials = UsageError(
    UsageErrorKind.noCredentials,
    'ClaudeBar reads usage through the claude CLI, which isn’t signed in — its login may have expired. Claude Desktop signs in separately, so it can look fine meanwhile.',
  );

  static const network = UsageError(
    UsageErrorKind.network,
    'Couldn’t reach the usage endpoint. Showing the last reading.',
  );

  static const noData = UsageError(
    UsageErrorKind.noData,
    'Claude Code answered but didn’t include usage this time. Showing the last reading — ClaudeBar will retry shortly.',
  );

  static const parseFailed = UsageError(
    UsageErrorKind.parseFailed,
    'Couldn’t understand Claude Code’s /usage reply — a Claude Code update may have changed its format. Check for a newer ClaudeBar.',
  );
}
