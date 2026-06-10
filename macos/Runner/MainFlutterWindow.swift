import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSPanel {
  // Menu-bar popover: keep the window non-opaque so only the rounded card drawn
  // by Flutter shows. window_manager's `setAsFrameless()` hard-sets
  // `isOpaque = true`, which over a clear background renders as a black box —
  // so we force every write to `false` (a real `false` write is what actually
  // reconfigures the backing surface to carry an alpha channel).
  override var isOpaque: Bool {
    get { super.isOpaque }
    set { super.isOpaque = false }
  }

  // The popover must take key status when ordered front so clicks/keys land in
  // Flutter and window_manager's resign-key → blur → auto-hide keeps working.
  override var canBecomeKey: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()

    // Non-activating panel: the popover can become key on its own without ever
    // activating the app. A plain NSWindow here needs `NSApp.activate(...)` to
    // take focus, which steals key status from whatever app the user is in and
    // — worse — leaves this windowless agent app active after the popover
    // hides, so every keystroke system-wide goes nowhere and the cursor
    // flickers until the user clicks another app.
    self.styleMask.insert(.nonactivatingPanel)
    // NSPanel defaults to hiding whenever the app deactivates; visibility is
    // driven explicitly by PopoverChannel/window_manager instead.
    self.hidesOnDeactivate = false
    // The xib shows the window at launch; keep the popover offstage until the
    // tray icon is clicked so startup never grabs key focus or flashes a card.
    self.setIsVisible(false)

    // Transparent menu-bar popover. Per FlutterViewController.h, the FlutterView
    // defaults to a BLACK background unless its `backgroundColor` is set to
    // clear — that, plus a non-opaque clear window, is what lets the rounded
    // card float over the desktop.
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    flutterViewController.backgroundColor = .clear

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Read-only Keychain bridge for the Claude Code credentials (spec §7).
    KeychainChannel.register(with: flutterViewController.registrar(forPlugin: "KeychainChannel"))

    // Activation-free show/hide for the popover (see PopoverChannel).
    PopoverChannel.register(
      with: flutterViewController.registrar(forPlugin: "PopoverChannel"),
      window: self
    )

    super.awakeFromNib()
  }
}

/// Shows/hides the popover panel without touching app activation.
///
/// window_manager's `show()`/`focus()` both call `NSApp.activate(...)`, which
/// is what a normal document window wants but is poison for a menu-bar
/// popover: the agent app stays active with no window after hiding, swallowing
/// all keyboard input. `makeKeyAndOrderFront` on a `.nonactivatingPanel` gives
/// the popover key status while the user's frontmost app stays active, and
/// `orderOut` hands key straight back to that app's window.
enum PopoverChannel {
  static let channelName = "claudebar/popover"

  static func register(with registrar: FlutterPluginRegistrar, window: NSWindow) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { [weak window] call, result in
      switch call.method {
      case "show":
        window?.makeKeyAndOrderFront(nil)
        result(true)
      case "hide":
        window?.orderOut(nil)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
