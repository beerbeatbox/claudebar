import 'package:flutter/services.dart';

/// Dart side of the read-only Keychain bridge (Swift in
/// `macos/Runner/MainFlutterWindow.swift`). Returns the raw JSON string for
/// the `Claude Code-credentials` generic-password item, or null.
class Keychain {
  static const MethodChannel _channel = MethodChannel('claudebar/keychain');

  /// Returns the credential JSON string, or null if missing/denied. A
  /// PlatformException (e.g. access denied) is reported via [accessDenied].
  Future<String?> readClaudeCredentials() async {
    accessDenied = false;
    try {
      return await _channel.invokeMethod<String>('readClaudeCredentials');
    } on PlatformException {
      accessDenied = true;
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Set when the last read failed with a platform error (best-effort signal
  /// that the user denied Keychain access).
  bool accessDenied = false;
}
