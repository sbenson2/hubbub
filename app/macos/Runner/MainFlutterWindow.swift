import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Discord's desktop proportions: open at 1280x800, never smaller than 940x600.
    self.contentMinSize = NSSize(width: 940, height: 600)
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.center()
    // A dark title strip in the rail colour (#1E1F22) instead of the light system bar.
    self.appearance = NSAppearance(named: .darkAqua)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.backgroundColor = NSColor(srgbRed: 30 / 255.0, green: 31 / 255.0, blue: 34 / 255.0, alpha: 1)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
