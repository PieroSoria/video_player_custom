import Flutter
import UIKit
import AVFoundation
import AVKit

public class VideoPlayerPipPlugin: NSObject, FlutterPlugin, AVPictureInPictureControllerDelegate {
  // MARK: - State

  var channel: FlutterMethodChannel?
  var pipController: AVPictureInPictureController?
  var isInPipMode = false
  var observationToken: NSKeyValueObservation?
  var pipCompletion: FlutterResult?
  /// The AVPlayer currently used by the PiP controller, kept so we can resume it
  /// if the system (or another plugin) pauses it while in background PiP.
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
    let channel = FlutterMethodChannel(name: "video_player_pip", binaryMessenger: registrar.messenger())
    let instance = VideoPlayerPipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.pipLog("VideoPlayerPip: Plugin registered")
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

  /// Fully resets PiP state: releases the controller, invalidates observers,
  /// clears the retained player, deactivates the audio session and resets the
  /// PiP flag. Safe to call any time (idempotent). Exposed to Flutter via the
  /// `reset` method call.
  func reset() {
    let hadController = pipController != nil
    let hadPlayer = pipPlayer != nil

    pipLog("VideoPlayerPip: reset() called — cleaning video + audio state")

    // 0) Force-stop the AVPlayer we know about. This is the SAME instance
    //    video_player created (we captured it from the AVPlayerLayer), so pausing
    //    it and emptying its item kills both the inline playback and any residual
    //    audio, no matter which module "owns" it. Without this, the player can
    //    keep sounding after its view is gone (audio with no image).
    if let player = pipPlayer {
      let rate = player.rate
      let tcs = player.timeControlStatus.rawValue
      let hasItem = player.currentItem != nil
      pipLog("VideoPlayerPip: reset() known player BEFORE stop: rate=\(rate) tcs=\(tcs) hasItem=\(hasItem)")
      player.pause()
      player.replaceCurrentItem(with: nil)
      pipLog("VideoPlayerPip: known player paused + currentItem cleared (audio should stop now)")
    } else {
      pipLog("VideoPlayerPip: reset() had NO retained player reference — audio (if any) comes from another module")
    }

    // 1) Video / PiP machinery
    cleanupPipController()

    // 2) Audio session: deactivate it so it doesn't stay in .playback and
    //    block/duck other apps' audio after leaving the video screen.
    do {
      let session = AVAudioSession.sharedInstance()
      if session.category == .playback {
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
        pipLog("VideoPlayerPip: Audio session deactivated (was .playback) — audio cleaned")
      } else {
        pipLog("VideoPlayerPip: Audio session left untouched (category=\(session.category.rawValue), active=\(session.isOtherAudioPlaying ? "other app playing" : "\(session.isInputAvailable)"))")
      }
    } catch {
      pipLog("VideoPlayerPip: Audio session deactivation note: \(error)")
    }

    isInPipMode = false
    pipCompletion = nil

    pipLog("VideoPlayerPip: reset() done — video(PiP controller)=\(hadController ? "cleaned" : "none"), player=\(hadPlayer ? "cleaned" : "none")")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    pipLog("VideoPlayerPip: Plugin being deallocated")
    cleanupPipController()
  }
}
