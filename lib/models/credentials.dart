/// Parsed Claude Code OAuth credentials (spec §7). Read-only — ClaudeBar
/// never writes these back.
class ClaudeCredentials {
  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scopes;

  /// e.g. "max", "pro", "team", "enterprise" — used for the plan badge.
  final String? subscriptionType;

  const ClaudeCredentials({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    required this.scopes,
    this.subscriptionType,
  });

  /// The usage endpoint requires the `user:profile` scope; a token with only
  /// `user:inference` cannot call it (spec §3a).
  bool get canReadUsage => scopes.contains('user:profile');

  /// Pretty plan label for the badge, e.g. "Max".
  String get planLabel {
    final raw = subscriptionType;
    if (raw == null || raw.isEmpty) return 'Claude';
    return raw[0].toUpperCase() + raw.substring(1).toLowerCase();
  }

  /// Tolerates both the nested `claudeAiOauth` envelope and a flat object,
  /// and both camelCase and snake_case keys (spec §7 — VERIFY against real
  /// data; built defensively).
  static ClaudeCredentials? fromJson(Map<String, dynamic> root) {
    final obj = (root['claudeAiOauth'] ?? root['claude_ai_oauth'] ?? root)
        as Map<String, dynamic>;

    final token = (obj['accessToken'] ?? obj['access_token']) as String?;
    if (token == null || token.isEmpty) return null;

    final scopesRaw = obj['scopes'] ?? obj['scope'];
    final scopes = <String>[];
    if (scopesRaw is List) {
      scopes.addAll(scopesRaw.map((e) => e.toString()));
    } else if (scopesRaw is String) {
      scopes.addAll(scopesRaw.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty));
    }

    return ClaudeCredentials(
      accessToken: token,
      refreshToken: (obj['refreshToken'] ?? obj['refresh_token']) as String?,
      expiresAt: _parseExpiry(obj['expiresAt'] ?? obj['expires_at']),
      scopes: scopes,
      subscriptionType:
          (obj['subscriptionType'] ?? obj['subscription_type'] ?? obj['rate_limit_tier'])
              as String?,
    );
  }

  static DateTime? _parseExpiry(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      // Heuristic: epoch ms vs epoch s.
      return value > 1000000000000
          ? DateTime.fromMillisecondsSinceEpoch(value)
          : DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    if (value is String) {
      final asInt = int.tryParse(value);
      if (asInt != null) return _parseExpiry(asInt);
      return DateTime.tryParse(value);
    }
    return null;
  }
}
