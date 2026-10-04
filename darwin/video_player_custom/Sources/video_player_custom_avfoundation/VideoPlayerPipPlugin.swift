#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import AVKit

public class VideoPlayerPipPlugin: NSObject, FlutterPlugin, AVPictureInPictureControllerDelegate {
  // MARK: - State

  var channel: FlutterMethodChannel?
  var playerLayerProvider: (Int64) -> AVPlayerLayer? = { _ in nil }
  var pausePlayer: (Int64) -> Void = { _ in }
  var playerId: Int64?
  var restoring = false
  var exitingFromApp = false
  var resetting = false
  var startingPip = false
  var stoppingPip = false
  var startTimeout: DispatchWorkItem?
  var pipController: AVPictureInPictureController?
  var isInPipMode = false
  var observationToken: NSKeyValueObservation?
  var pipCompletion: FlutterResult?
  /// Retain the exact source even if navigation removes its inline layer.
  var pipPlayer: AVPlayer?

  // MARK: - Flutter bridging

  /// Sends a method call to Flutter, always on the main thread (Flutter's
  /// method channel is not safe to call from background threads and doing so
  /// can block the UI / freeze gestures).
  func sendToFlutter(_ method: String, arguments: Any?) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(method, arguments: arguments)
    }
  }

  /// Logs a message both to the native console (NSLog) and forwards it to Flutter
  /// via the `nativeLog` method call so it can be printed in the Dart console.
  ///
  /// Debug-only: the whole body is compiled out in release builds to avoid the
  /// overhead of a MethodChannel round-trip on every log.
  func pipLog(_ message: String) {
    #if DEBUG
      NSLog(message)
      sendToFlutter("nativeLog", arguments: message)
    #endif
  }

  // MARK: - Registration

  public static func register(with registrar: FlutterPluginRegistrar) {
    register(with: registrar, playerLayerProvider: { _ in nil })
  }

  @discardableResult static func register(
    with registrar: FlutterPluginRegistrar,
    playerLayerProvider: @escaping (Int64) -> AVPlayerLayer?,
    pausePlayer: @escaping (Int64) -> Void = { _ in }
  ) -> VideoPlayerPipPlugin {
    let channel = FlutterMethodChannel(name: "video_player_pip", binaryMessenger: registrar.messenger())
    let instance = VideoPlayerPipPlugin(channel: channel)
    instance.playerLayerProvider = playerLayerProvider
    instance.pausePlayer = pausePlayer
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.pipLog("VideoPlayerPip: Plugin registered")
    return instance
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    setupLifecycleObservers()
    pipLog("VideoPlayerPip: Plugin initialized")
  }

  // MARK: - Method channel handling

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    pipLog("VideoPlayerPip: Received method call: \(call.method)")
    switch call.method {
    case "isPipSupported":
      let supported = isPipSupported()
      pipLog("VideoPlayerPip: isPipSupported = \(supported)")
      result(supported)

    case "enterPipMode":
      guard let args = call.arguments as? [String: Any],
            let playerId = args["playerId"] as? Int else {
        pipLog("VideoPlayerPip: enterPipMode failed - Invalid arguments")
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing playerId", details: nil))
        return
      }

      pipLog("VideoPlayerPip: Attempting to enter PiP mode for playerId: \(playerId)")
      enterPipMode(playerId: playerId, completion: result)

    case "exitPipMode":
      pipLog("VideoPlayerPip: Attempting to exit PiP mode, current isInPipMode = \(isInPipMode), pipController exists: \(pipController != nil)")
      exitPipMode(completion: result)

    case "isInPipMode":
      pipLog("VideoPlayerPip: isInPipMode query = \(isInPipMode)")
      result(isInPipMode)

    case "reset":
      pipLog("VideoPlayerPip: reset called, cleaning up PiP state")
      reset()
      result(nil)

    default:
      pipLog("VideoPlayerPip: Method not implemented: \(call.method)")
      result(FlutterMethodNotImplemented)
    }
  }

  func isPipSupported() -> Bool {
    if #available(iOS 14.0, *) {
      let supported = AVPictureInPictureController.isPictureInPictureSupported()
      pipLog("VideoPlayerPip: PiP supported by system: \(supported)")
      return supported
    }
    pipLog("VideoPlayerPip: PiP not supported (iOS < 14.0)")
    return false
  }

  /// Stop only this session's source. Never clear its item or deactivate the
  /// shared audio session, which another screen may already be using.
  func reset(playerId id: Int64? = nil) {
    if let id, id != playerId { return }
    if resetting { return }
    resetting = true
    pauseSource()
    finishStart(false)
    if let pipController, pipController.isPictureInPictureActive || isInPipMode {
      pipController.stopPictureInPicture()
    } else {
      cleanupPipController()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    pipLog("VideoPlayerPip: Plugin being deallocated")
    cleanupPipController()
  }
}

#endif
