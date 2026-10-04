#if os(macOS)
import AppKit
import AVKit
import FlutterMacOS

/// Native macOS PiP sourced from this engine's existing inline AVPlayerLayer.
final class MacVideoPlayerPipPlugin: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private let layerProvider: (Int64) -> AVPlayerLayer?
  private let pausePlayer: (Int64) -> Void
  private let restoreWindow: () -> Void
  private var controller: AVPictureInPictureController?
  private var sourcePlayer: AVPlayer?
  private var playerId: Int64?
  private var pendingStart: FlutterResult?
  private var readiness: NSKeyValueObservation?
  private var timeout: DispatchWorkItem?
  private var resetting = false
  private var restoring = false
  private var exitingFromApp = false

  init(registrar: FlutterPluginRegistrar, layerProvider: @escaping (Int64) -> AVPlayerLayer?,
       pausePlayer: @escaping (Int64) -> Void) {
    channel = FlutterMethodChannel(name: "video_player_pip", binaryMessenger: registrar.messenger)
    self.layerProvider = layerProvider
    self.pausePlayer = pausePlayer
    self.restoreWindow = { [weak view = registrar.view] in
      view?.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(false); return }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isPipSupported": result(AVPictureInPictureController.isPictureInPictureSupported())
    case "isInPipMode": result(controller?.isPictureInPictureActive ?? false)
    case "enterPipMode":
      guard let args = call.arguments as? [String: Any], let id = args["playerId"] as? NSNumber else {
        result(false); return
      }
      enter(id.int64Value, result: result)
    case "exitPipMode":
      guard let controller, controller.isPictureInPictureActive else { result(false); return }
      exitingFromApp = true
      controller.stopPictureInPicture()
      result(true)
    case "reset": reset(); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func enter(_ id: Int64, result: @escaping FlutterResult) {
    if let controller, controller.isPictureInPictureActive {
      result(playerId == id); return
    }
    guard !resetting, pendingStart == nil,
          AVPictureInPictureController.isPictureInPictureSupported(),
          let layer = layerProvider(id), layer.player?.currentItem != nil,
          let pip = AVPictureInPictureController(playerLayer: layer) else {
      result(false); return
    }
    clear()
    controller = pip
    sourcePlayer = layer.player
    playerId = id
    pendingStart = result
    pip.delegate = self
    restoreWindow()
    #if DEBUG
      channel.invokeMethod("nativeLog", arguments: "Mac PiP ready=\(pip.isPictureInPicturePossible) layerReady=\(layer.isReadyForDisplay) bounds=\(layer.bounds) attached=\(layer.superlayer != nil)")
    #endif
    readiness = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] pip, _ in
      DispatchQueue.main.async {
        guard let self, self.controller === pip, self.pendingStart != nil,
              pip.isPictureInPicturePossible else { return }
        self.readiness?.invalidate()
        self.readiness = nil
        pip.startPictureInPicture()
      }
    }
    let work = DispatchWorkItem { [weak self, weak pip] in
      guard let self, let pip, self.controller === pip, self.pendingStart != nil else { return }
      self.channel.invokeMethod("pipError", arguments: ["error": "macOS PiP did not start within 5 seconds (possible=\(pip.isPictureInPicturePossible), layerReady=\(pip.playerLayer.isReadyForDisplay))"])
      self.finishStart(false)
      self.clear()
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    if pip.isPictureInPicturePossible {
      readiness?.invalidate()
      readiness = nil
      pip.startPictureInPicture()
    }
  }

  func reset(playerId id: Int64? = nil) {
    if let id, id != playerId { return }
    finishStart(false)
    if let controller, controller.isPictureInPictureActive {
      resetting = true
      controller.stopPictureInPicture()
    } else {
      clear()
    }
  }

  private func finishStart(_ success: Bool) {
    readiness?.invalidate(); readiness = nil
    timeout?.cancel(); timeout = nil
    let completion = pendingStart
    pendingStart = nil
    completion?(success)
  }

  private func clear() {
    readiness?.invalidate(); readiness = nil
    timeout?.cancel(); timeout = nil
    controller?.delegate = nil
    controller = nil
    sourcePlayer = nil
    playerId = nil
    resetting = false
    restoring = false
    exitingFromApp = false
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard controller === pictureInPictureController else { return }
    channel.invokeMethod("pipModeChanged", arguments: ["isInPipMode": true])
    finishStart(true)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                  failedToStartPictureInPictureWithError error: Error) {
    guard controller === pictureInPictureController else { return }
    channel.invokeMethod("pipError", arguments: ["error": error.localizedDescription])
    finishStart(false)
    clear()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard controller === pictureInPictureController else { return }
    let shouldRestore = restoring && !exitingFromApp && !resetting
    let seconds = sourcePlayer?.currentTime().seconds ?? 0
    // A system stop ends playback on the source, including a restore that may
    // create a new Flutter controller. Update the wrapper's playback intent so
    // buffering callbacks cannot restart the old AVPlayer.
    if !exitingFromApp && !resetting { pauseSource() }
    logStop("didStop restore=\(shouldRestore)")
    clear()
    finishStart(false)
    if shouldRestore {
      channel.invokeMethod("onPipRestore", arguments: ["positionMs": seconds.isFinite ? Int64(max(0, seconds) * 1000) : 0])
    } else {
      channel.invokeMethod("pipModeChanged", arguments: ["isInPipMode": false])
    }
  }

  private func pauseSource() {
    if let playerId { pausePlayer(playerId) }
    // Keep the exact source available even if the native view is detached.
    sourcePlayer?.pause()
  }

  private func logStop(_ phase: String) {
    #if DEBUG
      channel.invokeMethod("nativeLog", arguments: "Mac PiP \(phase) player=\(playerId ?? -1) rate=\(sourcePlayer?.rate ?? -1) appExit=\(exitingFromApp) reset=\(resetting)")
    #endif
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard controller === pictureInPictureController else { return }
    if !exitingFromApp && !resetting { pauseSource() }
    logStop("willStop")
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard controller === pictureInPictureController, !resetting else { completionHandler(false); return }
    restoring = true
    if !exitingFromApp { pauseSource() }
    logStop("restore")
    restoreWindow()
    // Notify Flutter after didStop, when the old player is paused and PiP has
    // released its state. Navigation can then reuse or replace the controller.
    completionHandler(true)
  }

  deinit {
    timeout?.cancel()
    readiness?.invalidate()
    controller?.delegate = nil
    controller?.stopPictureInPicture()
    channel.setMethodCallHandler(nil)
  }
}
#endif
