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
      case "startCallAudio":
        EarDetection.shared.start()
        result(nil)
      case "stopCallAudio":
        EarDetection.shared.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }
}

/// Ear detection during a call, like the Phone app: held to the ear
/// (proximity sensor), audio on the loudspeaker or a Bluetooth device moves
/// to the earpiece, and iOS turns the screen off; taken away, it goes back
/// to that speaker / Bluetooth device. Wired headphones are left alone.
final class EarDetection {
  static let shared = EarDetection()

  private enum Back { case speaker, bluetooth(AVAudioSessionPortDescription?) }

  private var running = false
  private var back: Back?
  private var observer: NSObjectProtocol?
  private var pendingAway: DispatchWorkItem?

  /// Same as the audio library sets up (packages/intercom_audio): talk and
  /// listen, loudspeaker by default, Bluetooth headsets allowed.
  private let callOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]

  func start() {
    guard !running, UIDevice.current.userInterfaceIdiom == .phone else { return }
    running = true
    UIDevice.current.isProximityMonitoringEnabled = true
    observer = NotificationCenter.default.addObserver(
      forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.pendingAway?.cancel()
      if UIDevice.current.proximityState {
        self.toEar()
      } else {
        // Back only once it stays away a moment (no flapping).
        let work = DispatchWorkItem { [weak self] in self?.awayFromEar() }
        self.pendingAway = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
      }
    }
  }

  func stop() {
    guard running else { return }
    running = false
    pendingAway?.cancel()
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    observer = nil
    UIDevice.current.isProximityMonitoringEnabled = false
    if back != nil { awayFromEar() }
  }

  private func toEar() {
    guard back == nil else { return }
    let session = AVAudioSession.sharedInstance()
    guard let out = session.currentRoute.outputs.first?.portType else { return }
    do {
      switch out {
      case .builtInSpeaker:
        back = .speaker
        // Without "default to speaker" the call plays on the earpiece.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        try session.overrideOutputAudioPort(.none)
      case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
        let bt = session.currentRoute.inputs.first { $0.portType == .bluetoothHFP }
        back = .bluetooth(bt)
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        // Choosing the built-in microphone moves the call off Bluetooth,
        // onto the earpiece.
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
          try session.setPreferredInput(mic)
        }
        try session.overrideOutputAudioPort(.none)
      default:
        return // Earpiece already, or wired headphones.
      }
    } catch {
      NSLog("Ear detection: could not switch to the earpiece: \(error)")
    }
  }

  private func awayFromEar() {
    guard let previous = back else { return }
    back = nil
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: callOptions)
      switch previous {
      case .speaker:
        try session.setPreferredInput(nil)
        try session.overrideOutputAudioPort(.speaker)
      case .bluetooth(let port):
        let bt = port ?? session.availableInputs?.first { $0.portType == .bluetoothHFP }
        try session.setPreferredInput(bt)
      }
    } catch {
      NSLog("Ear detection: could not switch back: \(error)")
    }
  }
}
