import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Mirrors a diagnostic line to debugPrint AND to native os_log, so a release
/// build can still be traced from Console.app / `log stream` (debugPrint is
/// stripped in release; os_log is not).
///
/// Lines land in subsystem "one.beatbox.claudeUsageBar", so the capsule
/// capture (scripts/capture_focus_log.sh) picks them up interleaved with
/// FocusSentinel's own events — which is the point: it puts what ClaudeBar was
/// DOING on the same timeline as what the input source was doing.
class Diag {
  Diag._();

  /// The native side of this channel os_logs whatever it is handed; it is the
  /// tray recovery channel because that is where the handler already lives.
  static const MethodChannel _channel = MethodChannel('claudebar/tray');

  static void log(String message) {
    debugPrint('[ClaudeBar] $message');
    // Fire-and-forget: a missing handler (unit tests, an isolate without the
    // plugin) must never surface as an unhandled async error from a log call.
    _channel.invokeMethod('log', message).catchError((Object _) => null);
  }
}
