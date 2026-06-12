/// The distinct failure modes ClaudeBar surfaces, each mapped to a clear
/// user-facing message and menu-bar label (spec §11).
///
/// All usage flows through the `claude` CLI, so the kinds mirror the ways a
/// CLI probe can fail — classified by CliUsageSource so each one gets the
/// right UX instead of a silent fallback that would mask the cause.
enum UsageErrorKind {
  /// The `claude` binary couldn't be found on this machine.
  cliMissing,

  /// The CLI is installed but reports it isn't signed in.
  noCredentials,

  /// The CLI ran but couldn't reach Anthropic (machine offline, or the API
  /// is unreachable).
  network,

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

  /// Short text for the menu-bar status item.
  String get menuBarLabel {
    switch (kind) {
      case UsageErrorKind.cliMissing:
        return 'No CLI';
      case UsageErrorKind.noCredentials:
        return 'Sign in';
      case UsageErrorKind.network:
      case UsageErrorKind.parseFailed:
      case UsageErrorKind.unknown:
        return '--%';
    }
  }

  /// Heading + body for the popover status state.
  String get title {
    switch (kind) {
      case UsageErrorKind.cliMissing:
        return 'Claude Code not found';
      case UsageErrorKind.noCredentials:
        return 'Sign in to Claude Code';
      case UsageErrorKind.network:
        return 'Can’t reach Anthropic';
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
    'Sign in to Claude Code — ClaudeBar will pick it up shortly, or right-click the menu-bar icon → Refresh.',
  );

  static const network = UsageError(
    UsageErrorKind.network,
    'Couldn’t reach the usage endpoint. Showing the last reading.',
  );

  static const parseFailed = UsageError(
    UsageErrorKind.parseFailed,
    'Couldn’t understand Claude Code’s /usage reply — a Claude Code update may have changed its format. Check for a newer ClaudeBar.',
  );
}
