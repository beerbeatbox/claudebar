import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/credentials.dart';
import '../models/usage_error.dart';
import 'keychain.dart';

/// Outcome of resolving credentials: either a [ClaudeCredentials] or a
/// [UsageError] describing why we couldn't.
class CredentialsResult {
  final ClaudeCredentials? credentials;
  final UsageError? error;

  const CredentialsResult.ok(this.credentials) : error = null;
  const CredentialsResult.fail(this.error) : credentials = null;

  bool get isOk => credentials != null;
}

/// Resolves Claude Code credentials, file first then Keychain (spec §7).
///
/// Successful reads are cached in memory for as long as the token is valid,
/// so the Keychain — and its password prompt on machines that haven't granted
/// "Always Allow" — is touched once per app run, not on every refresh. The
/// cache is dropped when the token nears [_expiryMargin] of its `expiresAt`,
/// or eagerly via [invalidate] when the API rejects it with a 401 (Claude
/// Code rotates the stored token, so a fresh read picks up the new one).
class CredentialsReader {
  CredentialsReader({Keychain? keychain}) : _keychain = keychain ?? Keychain();

  final Keychain _keychain;

  ClaudeCredentials? _cached;

  /// Refresh the cache slightly before the token actually expires, so we
  /// never hand out a token that dies mid-request.
  static const _expiryMargin = Duration(minutes: 2);

  /// Drops the cached credentials so the next [read] hits the file/Keychain
  /// again — call when the API says the token is no longer valid.
  void invalidate() => _cached = null;

  Future<CredentialsResult> read() async {
    final cached = _cached;
    if (cached != null && !_nearsExpiry(cached)) {
      return CredentialsResult.ok(cached);
    }
    _cached = null;

    String? raw = await _readFile();
    raw ??= await _keychain.readClaudeCredentials();

    if (raw == null || raw.trim().isEmpty) {
      if (_keychain.accessDenied) {
        return const CredentialsResult.fail(UsageError.keychainDenied);
      }
      return const CredentialsResult.fail(UsageError.noCredentials);
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[ClaudeBar] failed to decode credentials JSON: $e');
      return const CredentialsResult.fail(UsageError.noCredentials);
    }

    if (kDebugMode) {
      debugPrint('[ClaudeBar] credential keys: ${_describeKeys(json)}');
    }

    final creds = ClaudeCredentials.fromJson(json);
    if (creds == null) {
      return const CredentialsResult.fail(UsageError.noCredentials);
    }
    if (!creds.canReadUsage) {
      return const CredentialsResult.fail(UsageError.missingScope);
    }
    _cached = creds;
    return CredentialsResult.ok(creds);
  }

  /// Whether the token is expired or about to be. A token with no
  /// `expiresAt` stays cached indefinitely — the 401 → [invalidate] path is
  /// the backstop there.
  bool _nearsExpiry(ClaudeCredentials creds) {
    final expiresAt = creds.expiresAt;
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt.subtract(_expiryMargin));
  }

  /// Reads `~/.claude/.credentials.json` if present (spec §7, step 1).
  Future<String?> _readFile() async {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final file = File('$home/.claude/.credentials.json');
    try {
      if (await file.exists()) return await file.readAsString();
    } catch (e) {
      debugPrint('[ClaudeBar] failed to read credentials file: $e');
    }
    return null;
  }

  /// Logs only the *key names* (never the secret values) for the VERIFY step.
  String _describeKeys(Map<String, dynamic> json) {
    final nested = json['claudeAiOauth'] ?? json['claude_ai_oauth'];
    final inner = nested is Map ? nested : json;
    return inner.keys.join(', ');
  }
}
