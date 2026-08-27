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

  // The user relaunched ClaudeBar while it was already running — almost always
  // because the menu-bar icon vanished after a long sleep/wake and they tried to
  // "open it again" from Applications/Spotlight/Dock. ClaudeBar is a single
  // instance LSUIElement agent, so LaunchServices routes that reopen to the live
  // instance instead of starting a new one; with no handler it's a silent no-op,
  // which is exactly the "it won't open" people report. Treat the reopen as an
  // explicit "bring the icon back" and force-recreate the status item (force, so
  // it fires even for a force-hidden item that still reports valid bounds and
  // would otherwise be skipped by the bounds-based wake recovery).
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    TrayRecoveryChannel.requestRecover(force: true, source: "reopen")
    return true
  }

  // Held for the lifetime of the app so macOS never puts ClaudeBar into App
  // Nap. A windowless LSUIElement agent is App Nap's prime candidate, and a
  // napped app has its timers coalesced and suspended — which stalls the usage
  // refresh interval for minutes at a time and leaves the menu bar showing a
  // stale reading until the user hits Refresh by hand. The app is idle between
  // probes, so opting out costs effectively nothing.
  private var activityToken: NSObjectProtocol?

  // Running straight from the mounted .dmg crashes the moment the image is
  // ejected: once the backing vnode is force-unmounted, the next page-in of the
  // app's code raises SIGBUS (we saw exactly this in a crash report). Nudge the
  // user to install into /Applications before that can happen.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    activityToken = ProcessInfo.processInfo.beginActivity(
      // .userInitiatedAllowingIdleSystemSleep is the option that actually
      // opts out of App Nap (.background does not) while still letting the
      // Mac go to sleep normally — ClaudeBar must not keep a laptop awake.
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "ClaudeBar refreshes usage on a timer"
    )
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
