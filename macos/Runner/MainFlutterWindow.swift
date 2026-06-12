import Cocoa
import FlutterMacOS
import Security

/// Native frosted-glass backdrop for the popover card, like a real macOS menu.
///
/// Flutter's BackdropFilter can only blur Flutter's own pixels; blurring the
/// desktop behind the window requires an AppKit NSVisualEffectView. It is
/// masked to the same bubble-with-arrow shape the Dart side paints, so the
/// blur never leaks into the transparent shadow gutter around the card.
///
/// Placement is delicate — both in-window homes are broken:
/// - In the frame view (contentView.superview) AppKit stops routing mouse
///   events to the content view entirely; every click in the popover goes
///   dead.
/// - Inside the layer-backed Flutter hierarchy, behind-window blending
///   silently falls back to a flat opaque fill — no desktop shows through.
/// So it lives in [BlurBackdropWindow], a click-through child window ordered
/// just below the popover panel.
final class PopoverBlurView: NSVisualEffectView {
  // Card geometry mirrored from popover_panel.dart / popover_window.dart:
  // 40 pt side gutter, 64 pt bottom gutter, 8 pt arrow, 9 pt arrow half-width,
  // 14 pt corner radius. Keep the two in sync.
  static let gutterSide: CGFloat = 40
  static let gutterBottom: CGFloat = 64
  static let arrowHeight: CGFloat = 8
  static let arrowHalfWidth: CGFloat = 9
  static let cornerRadius: CGFloat = 14

  /// Arrow-centre distance from the window's right edge; pushed from Dart by
  /// the window positioner so the mask tracks the status item.
  var arrowFromRight: CGFloat = 70 {
    didSet { rebuildMask() }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    material = .menu
    blendingMode = .behindWindow
    // The popover is a non-activating panel, so it never counts as the active
    // window; without forcing .active the material renders flat and opaque.
    state = .active
    autoresizingMask = [.width, .height]
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    rebuildMask()
  }

  private func rebuildMask() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let size = bounds.size
    let arrowFromRight = self.arrowFromRight
    let image = NSImage(size: size, flipped: false) { _ in
      NSColor.black.setFill()
      Self.bubblePath(in: size, arrowFromRight: arrowFromRight).fill()
      return true
    }
    maskImage = image
  }

  /// The card-plus-arrow outline in AppKit (bottom-left origin) coordinates;
  /// must trace the same shape as _BubblePainter._bubblePath in Dart.
  static func bubblePath(in size: NSSize, arrowFromRight: CGFloat) -> NSBezierPath {
    let card = NSRect(
      x: gutterSide,
      y: gutterBottom,
      width: size.width - 2 * gutterSide,
      height: size.height - gutterBottom - arrowHeight)
    let path = NSBezierPath(roundedRect: card, xRadius: cornerRadius, yRadius: cornerRadius)

    let cx = size.width - arrowFromRight
    let top = size.height
    let base = card.maxY
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: cx - arrowHalfWidth, y: base))
    // Slightly rounded tip, matching the Dart painter.
    arrow.line(to: NSPoint(x: cx - 1.5, y: top - 1.33))
    arrow.curve(to: NSPoint(x: cx + 1.5, y: top - 1.33),
                controlPoint1: NSPoint(x: cx, y: top),
                controlPoint2: NSPoint(x: cx, y: top))
    arrow.line(to: NSPoint(x: cx + arrowHalfWidth, y: base))
    arrow.close()
    path.append(arrow)
    return path
  }
}

/// Borderless, click-through window that carries [PopoverBlurView] and rides
/// just below the popover panel as its child window. Being a plain window of
/// its own gives the effect view a non-layer-backed home where behind-window
/// blending actually blurs the desktop, and `ignoresMouseEvents` guarantees
/// it can never intercept a click meant for the popover.
final class BlurBackdropWindow: NSWindow {
  let blurView = PopoverBlurView(frame: .zero)

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    animationBehavior = .none
    // Follow the popover onto whichever Space/display it appears on.
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    contentView = blurView
  }

  /// Pins this window exactly under [panel] and keeps it there: child windows
  /// move with their parent, and resize/move notifications cover the popover's
  /// content-height changes while visible.
  func attach(below panel: NSWindow) {
    let sync = { [weak self, weak panel] (_: Notification) in
      guard let self, let panel else { return }
      self.setFrame(panel.frame, display: true)
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: panel, queue: .main, using: sync)
    NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: sync)
  }

  func show(under panel: NSWindow) {
    setFrame(panel.frame, display: true)
    level = panel.level
    panel.addChildWindow(self, ordered: .below)
  }

  func hide(from panel: NSWindow) {
    panel.removeChildWindow(self)
    orderOut(nil)
  }
}

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

    // Frosted backdrop in its own click-through child window (see
    // BlurBackdropWindow for why it cannot live inside this one).
    let backdrop = BlurBackdropWindow()
    backdrop.attach(below: self)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Read-only Keychain bridge for the Claude Code credentials (spec §7).
    KeychainChannel.register(with: flutterViewController.registrar(forPlugin: "KeychainChannel"))

    // Activation-free show/hide for the popover (see PopoverChannel).
    PopoverChannel.register(
      with: flutterViewController.registrar(forPlugin: "PopoverChannel"),
      window: self,
      backdrop: backdrop
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

  static func register(
    with registrar: FlutterPluginRegistrar,
    window: NSWindow,
    backdrop: BlurBackdropWindow
  ) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    // `backdrop` is captured strongly on purpose: nothing else owns it.
    channel.setMethodCallHandler { [weak window] call, result in
      switch call.method {
      case "show":
        if let window {
          window.makeKeyAndOrderFront(nil)
          backdrop.show(under: window)
        }
        result(true)
      case "hide":
        if let window {
          backdrop.hide(from: window)
          window.orderOut(nil)
        }
        result(true)
      // Keeps the blur mask's arrow under the status item; the Dart
      // positioner sends the same arrowFromRight it hands to the painter.
      case "setArrow":
        if let fromRight = call.arguments as? Double {
          backdrop.blurView.arrowFromRight = CGFloat(fromRight)
        }
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
