import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var platformChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Gundil Intercom"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // "p2p_intercom/platform" (lib/src/platform_bridge.dart): only the
    // microphone permission on macOS; the rest is Android-only.
    let ch = FlutterMethodChannel(
      name: "p2p_intercom/platform",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "requestMicrophone":
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
          result(true)
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { result(granted) }
          }
        default:
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    platformChannel = ch

    super.awakeFromNib()
  }
}
