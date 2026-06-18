import Cocoa
import FlutterMacOS
import os

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

  /// Height of the visible card (Flutter's measured content), pushed from Dart.
  /// The window is a fixed, taller-than-content height that never shrinks, so
  /// the card is masked at the TOP at this height; ≤ 0 means "fill the window"
  /// (the legacy behaviour, before the first push).
  var cardHeight: CGFloat = 0 {
    didSet { rebuildMask() }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    // .fullScreenUI is the most see-through of the appearance-adaptive
    // materials — .menu reads almost solid, hiding the desktop behind.
    material = .fullScreenUI
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
    // The card is masked at the top at its measured height; before Dart pushes
    // one (or for a full-height window) it fills the view.
    let card = cardHeight > 0 ? min(cardHeight, size.height) : size.height
    let image = NSImage(size: size, flipped: false) { _ in
      NSColor.black.setFill()
      Self.bubblePath(in: size, cardHeight: card, arrowFromRight: arrowFromRight).fill()
      return true
    }
    maskImage = image
  }

  /// The card-plus-arrow outline in AppKit (bottom-left origin) coordinates;
  /// must trace the same shape as _BubblePainter._bubblePath in Dart. The card
  /// is pinned to the TOP of the view (the arrow tip touches the view's top
  /// edge) and spans [cardHeight]; any extra view height below stays clear.
  static func bubblePath(in size: NSSize, cardHeight: CGFloat, arrowFromRight: CGFloat) -> NSBezierPath {
    let card = NSRect(
      x: gutterSide,
      y: size.height - cardHeight + gutterBottom,
      width: size.width - 2 * gutterSide,
      height: cardHeight - gutterBottom - arrowHeight)
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
  // Flutter and window_manager's resign-key → blur → auto-hide keeps working —
  // but ONLY then. At launch the nib orders this (transparent) window front so
  // the Flutter engine has a surface to render its first frame on, which is
  // what runs the Dart entrypoint that registers the menu-bar status item. If
  // the window can become key during that launch pass it captures system-wide
  // keyboard input for this windowless LSUIElement agent app: keystrokes go
  // nowhere and the text caret flickers in every app until ClaudeBar quits.
  // Gate key eligibility on the popover actually being presented — Popover
  // channel flips this true right before makeKeyAndOrderFront and false again
  // after orderOut — so launch can render (tray appears) without stealing focus.
  var popoverWantsKey = false
  override var canBecomeKey: Bool { popoverWantsKey }

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

    // Activation-free show/hide for the popover (see PopoverChannel).
    PopoverChannel.register(
      with: flutterViewController.registrar(forPlugin: "PopoverChannel"),
      window: self,
      backdrop: backdrop
    )

    // Tell Dart when the display topology changes so the tray can re-assert its
    // status item (macOS 26 detaches menu-bar items on display reconfig).
    TrayRecoveryChannel.register(
      with: flutterViewController.registrar(forPlugin: "TrayRecoveryChannel")
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
          // Allow key status only now that the user is opening the popover, so
          // typing lands in Flutter. At launch canBecomeKey stays false so the
          // window can render (registering the tray) without grabbing focus.
          (window as? MainFlutterWindow)?.popoverWantsKey = true
          window.makeKeyAndOrderFront(nil)
          backdrop.show(under: window)
        }
        result(true)
      case "hide":
        if let window {
          backdrop.hide(from: window)
          window.orderOut(nil)
          // Hand key back to the user's app and bar the hidden popover from
          // becoming key again until it is next presented.
          (window as? MainFlutterWindow)?.popoverWantsKey = false
        }
        result(true)
      // Updates the popover's layout. The window height is a fixed, grow-only
      // value (it never shrinks), so this almost never resizes the window —
      // which is the whole point: growing an NSWindow that hosts a FlutterView
      // blocks the main thread up to ~1s waiting on a Metal drawable. Switching
      // views only changes `cardHeight`, which re-masks the blur to hug the
      // card at the top while the window (and its render surface) stay put.
      case "resize":
        if let window, let args = call.arguments as? [String: Any] {
          if let w = args["width"] as? Double,
             let wh = args["windowHeight"] as? Double {
            let target = NSSize(width: CGFloat(w), height: CGFloat(wh))
            if window.frame.size != target {
              var f = window.frame
              f.origin.y += f.size.height - CGFloat(wh) // keep the top pinned
              f.size = target
              window.setFrame(f, display: true)
            }
          }
          if let ch = args["cardHeight"] as? Double {
            backdrop.blurView.cardHeight = CGFloat(ch)
          }
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

/// Nudges Dart to recreate its NSStatusItem whenever macOS is liable to have
/// dropped it. macOS 26 frequently detaches menu-bar items on display
/// reconfiguration (monitor connect/disconnect, dock/undock, resolution change)
/// AND across sleep/wake and screen lock/unlock, leaving the icon invisible
/// until the item is recreated (the sibling app CodexBar hit the same thing —
/// issues #1077/#1088).
///
/// Several distinct signals are needed, because none covers the others:
///   • didChangeScreenParametersNotification — display topology changes. Does
///     NOT fire on a plain idle-sleep→wake (no display reconfig).
///   • NSWorkspace didWake / screensDidWake — system + display sleep/wake. These
///     post on NSWorkspace's OWN notification center, not the default one.
///   • com.apple.screenIsUnlocked — locking the screen (⌃⌘Q) and unlocking it,
///     which need not put the display to sleep at all, so the wake signals above
///     can miss it. This is a distributed notification.
/// Dart recovers UNCONDITIONALLY on these (it cannot reliably tell a
/// force-hidden item from a present one — the system keeps isVisible == true and
/// the button frame valid even while the icon is gone), so we just fire on each.
enum TrayRecoveryChannel {
  static let channelName = "claudebar/tray"
  private static var channel: FlutterMethodChannel?
  private static var observers: [NSObjectProtocol] = []

  // os_log surfaces in Console.app even for release builds (unlike Dart's
  // debugPrint, which is stripped), so a beta tester can capture exactly which
  // signals fire on unlock and how the Dart-side recovery fares. Filter Console
  // by subsystem "one.beatbox.claudeUsageBar" (or just the ClaudeBar process).
  // OSLog (not the newer Logger) keeps this compiling for the 10.15 target.
  static let log = OSLog(subsystem: "one.beatbox.claudeUsageBar", category: "tray")

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    self.channel = channel

    // Dart pushes its recovery progress back here so the whole flow — trigger →
    // recreate → result — is visible in one Console stream in release builds.
    channel.setMethodCallHandler { call, result in
      if call.method == "log", let msg = call.arguments as? String {
        os_log("dart: %{public}@", log: log, type: .info, msg)
      }
      result(nil)
    }

    // Each of these can fire a burst; Dart debounces, so just forward them —
    // logging the source so we can see which actually arrives on unlock/wake.
    func nudge(_ source: String) -> (Notification) -> Void {
      { _ in
        os_log("recovery trigger: %{public}@", log: log, type: .info, source)
        channel.invokeMethod("recover", arguments: nil)
      }
    }

    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main, using: nudge("screenParameters")))

    // Sleep/wake lives on the workspace notification center.
    let workspace = NSWorkspace.shared.notificationCenter
    observers.append(workspace.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil, queue: .main, using: nudge("didWake")))
    observers.append(workspace.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil, queue: .main, using: nudge("screensDidWake")))
    // The session becoming active also fires on screen unlock (and fast user
    // switching) — a belt-and-suspenders for com.apple.screenIsUnlocked, whose
    // distributed delivery to an LSUIElement agent app can be unreliable.
    observers.append(workspace.addObserver(
      forName: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil, queue: .main, using: nudge("sessionDidBecomeActive")))

    // Screen unlock also posts here, on the distributed notification center.
    observers.append(DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"),
      object: nil, queue: .main, using: nudge("screenIsUnlocked")))

    os_log("tray recovery observers registered", log: log, type: .info)
  }
}

