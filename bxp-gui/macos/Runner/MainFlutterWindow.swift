import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Window title override — the storyboard's default "Window" caption
    // would otherwise show in the title bar even though the bundle name
    // is "BXP".
    self.title = "BXP"

    // Enforce a minimum content size of 1024x768 (kLogicalMinWidth/Height in
    // lib/ui/zoom_limits.dart). Same floor as the WM_GETMINMAXINFO override in
    // windows/runner/win32_window.cpp; the Linux runner pins a larger 1280x800
    // minimum in my_application.cc. Every panel split in the UI assumes at
    // least this much room.
    self.contentMinSize = NSSize(width: 1024, height: 768)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
