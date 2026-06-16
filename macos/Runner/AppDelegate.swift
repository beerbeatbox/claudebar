import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Menu-bar app: the popover window is hidden at startup and on blur, so the
  // app must stay alive without any visible window. Quitting happens explicitly
  // via the tray "Quit" item.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Running straight from the mounted .dmg crashes the moment the image is
  // ejected: once the backing vnode is force-unmounted, the next page-in of the
  // app's code raises SIGBUS (we saw exactly this in a crash report). Nudge the
  // user to install into /Applications before that can happen.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard Bundle.main.bundlePath.hasPrefix("/Volumes/") else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Move ClaudeBar to Applications"
    alert.informativeText = """
      ClaudeBar is running from a disk image. Drag it into your Applications \
      folder and open it from there — running from the mounted image makes it \
      crash as soon as the image is ejected.
      """
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Open Anyway")
    if alert.runModal() == .alertFirstButtonReturn {
      NSApp.terminate(nil)
    }
  }
}
