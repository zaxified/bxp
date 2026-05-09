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

    // Enforce a minimum content size of 1024x768. Mirrors the GTK
    // GdkGeometry hint in linux/runner/my_application.cc and the
    // WM_GETMINMAXINFO override in windows/runner/win32_window.cpp;
    // every panel split in the UI assumes at least this much room.
    self.contentMinSize = NSSize(width: 1024, height: 768)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
