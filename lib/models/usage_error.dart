/// The distinct failure modes ClaudeBar surfaces, each mapped to a clear
/// user-facing message and menu-bar label (spec §11).
enum UsageErrorKind {
  /// No `~/.claude/.credentials.json` and nothing in the Keychain.
  noCredentials,

  /// Token present but lacks the `user:profile` scope needed for usage.
  missingScope,

  /// Endpoint returned 401 — token expired.
  expiredToken,

  /// Network failure / non-401 HTTP error.
  network,

  /// Keychain access was denied by the user.
  keychainDenied,

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
      case UsageErrorKind.noCredentials:
        return 'Sign in';
      case UsageErrorKind.missingScope:
        return 'Re-auth';
      case UsageErrorKind.expiredToken:
        return 'Expired';
      case UsageErrorKind.keychainDenied:
        return 'Locked';
      case UsageErrorKind.network:
      case UsageErrorKind.unknown:
        return '--%';
    }
  }

  /// Heading + body for the popover status state.
  String get title {
    switch (kind) {
      case UsageErrorKind.noCredentials:
        return 'Sign in to Claude Code';
      case UsageErrorKind.missingScope:
        return 'Re-authenticate';
      case UsageErrorKind.expiredToken:
        return 'Re-authenticate';
      case UsageErrorKind.keychainDenied:
        return 'Keychain access needed';
      case UsageErrorKind.network:
        return 'Can’t reach Anthropic';
      case UsageErrorKind.unknown:
        return 'Something went wrong';
    }
  }

  static const noCredentials = UsageError(
    UsageErrorKind.noCredentials,
    'Sign in to Claude Code first, then hit Refresh.',
  );

  static const missingScope = UsageError(
    UsageErrorKind.missingScope,
    'This token can’t read usage — re-authenticate in Claude Code.',
  );

  static const expiredToken = UsageError(
    UsageErrorKind.expiredToken,
    'Your session token expired. Open Claude Code to refresh it, then hit Refresh.',
  );

  static const keychainDenied = UsageError(
    UsageErrorKind.keychainDenied,
    'Allow ClaudeBar to read “Claude Code-credentials” in Keychain Access → login → Access Control.',
  );

  static const network = UsageError(
    UsageErrorKind.network,
    'Couldn’t reach the usage endpoint. Showing the last reading.',
  );
}
