import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Read-only Keychain bridge for the Claude Code credentials (spec §7).
    KeychainChannel.register(with: flutterViewController.registrar(forPlugin: "KeychainChannel"))

    super.awakeFromNib()
  }
}

/// Bridges a single read-only Keychain lookup to Dart.
///
/// Reads the generic-password secret stored by Claude Code under the service
/// name `Claude Code-credentials` and returns its UTF-8 JSON string. The app
/// never writes to the Keychain — this is strictly read-only (see spec §2/§7).
enum KeychainChannel {
  static let channelName = "claudebar/keychain"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "readClaudeCredentials":
        result(readClaudeCredentials())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Returns the credential JSON string, or `nil` if the item is absent /
  /// unreadable. Access denial and "not found" both collapse to `nil`; the
  /// Dart layer turns that into a friendly error state.
  static func readClaudeCredentials() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
