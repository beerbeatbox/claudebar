import Cocoa
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {

  /// Regression test for the dead popover buttons shipped in v1.1.0: the
  /// frosted backdrop must stay transparent to hit-testing. Hover reaches
  /// Flutter through the FlutterView's tracking areas either way, but clicks
  /// route through NSWindow.sendEvent → hitTest, and when the backdrop wins
  /// it swallows every mouseDown — the gear highlighted on hover but did
  /// nothing when clicked.
  func testBlurBackdropIsHitTestTransparent() {
    let blur = PopoverBlurView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
    let points = [
      NSPoint(x: 190, y: 250),  // centre of the card
      NSPoint(x: 300, y: 110),  // bottom-right, where the settings gear sits
      NSPoint(x: 60, y: 450),   // top-left, inside the arrow strip
    ]
    for point in points {
      XCTAssertNil(
        blur.hitTest(point),
        "PopoverBlurView must never claim mouse events (failed at \(point))")
    }
  }

  /// The same property exercised through a real window: wherever a click
  /// lands inside the frame, the view AppKit resolves must never be the
  /// backdrop — AppKit does not guarantee hit-test order between overlapping
  /// siblings, so this must hold regardless of subview ordering.
  func testWindowHitTestNeverResolvesToTheBackdrop() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    let blur = PopoverBlurView(frame: window.contentView!.frame)
    blur.attach(to: window)

    guard let frameView = window.contentView?.superview else {
      return XCTFail("borderless window should still have a frame view")
    }
    for x in stride(from: CGFloat(5), to: 380, by: 75) {
      for y in stride(from: CGFloat(5), to: 500, by: 95) {
        let hit = frameView.hitTest(NSPoint(x: x, y: y))
        XCTAssertFalse(
          hit is PopoverBlurView,
          "a click at (\(x), \(y)) would be swallowed by the blur backdrop")
      }
    }
  }
}
