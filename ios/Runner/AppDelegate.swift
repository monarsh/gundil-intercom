import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GundilPlatform") {
      GundilPlatform.register(messenger: registrar.messenger())
    }
  }
}

/// The "p2p_intercom/platform" channel on iOS (lib/src/platform_bridge.dart):
/// only the microphone permission; the rest is Android-only.
enum GundilPlatform {
  static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "p2p_intercom/platform", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "requestMicrophone":
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async { result(granted) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }
}
