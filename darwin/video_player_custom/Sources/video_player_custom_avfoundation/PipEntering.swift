#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import AVKit

extension VideoPlayerPipPlugin {
  func enterPipMode(playerId id: Int, completion: @escaping FlutterResult) {
    guard !stoppingPip, !resetting else { completion(false); return }
    if let pipController, pipController.isPictureInPictureActive {
      completion(playerId == Int64(id)); return
    }
    guard !resetting, pipCompletion == nil, isPipSupported(),
          let layer = playerLayerProvider(Int64(id)),
          let player = layer.player, player.currentItem != nil,
          let controller = AVPictureInPictureController(playerLayer: layer) else {
      completion(false); return
    }
    cleanupPipController()
    playerId = Int64(id)
    pipPlayer = player
    pipController = controller
    pipCompletion = completion
    controller.delegate = self
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = true
    }
    controller.requiresLinearPlayback = false

    do {
      let session = AVAudioSession.sharedInstance()
      if session.category != .playback {
        try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
      }
      try session.setActive(true)
    } catch {
      pipLog("VideoPlayerPip: Audio session setup note: \(error)")
    }

    // Wait for readiness, rather than issuing repeated start calls or sending
    // state events from KVO ahead of the lifecycle delegate.
    observationToken = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, _ in
      DispatchQueue.main.async {
        guard let self, self.pipController === controller,
              self.pipCompletion != nil, controller.isPictureInPicturePossible else { return }
        self.startPip(controller)
      }
    }
    let timeout = DispatchWorkItem { [weak self, weak controller] in
      guard let self, let controller, self.pipController === controller,
            self.pipCompletion != nil else { return }
      self.pipLog("VideoPlayerPip: Timed out waiting for PiP to start")
      self.finishStart(false)
      self.cleanupPipController()
    }
    startTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    pipLog("VideoPlayerPip: Preparing player=\(id) possible=\(controller.isPictureInPicturePossible) layerReady=\(layer.isReadyForDisplay)")
    if controller.isPictureInPicturePossible { startPip(controller) }
  }

  private func startPip(_ controller: AVPictureInPictureController) {
    guard pipController === controller, !startingPip, !resetting else { return }
    startingPip = true
    observationToken?.invalidate()
    observationToken = nil
    // AVKit can still be settling the inline layer after a previous stop even
    // when possible is already true. Defer and bind both attempts to this
    // controller so a reset or a newer session cannot restart the old one.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak controller] in
      guard let self, let controller, self.pipController === controller,
            self.pipCompletion != nil, !self.resetting else { return }
      controller.startPictureInPicture()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak controller] in
      guard let self, let controller, self.pipController === controller,
            self.pipCompletion != nil, !self.resetting,
            !controller.isPictureInPictureActive else { return }
      self.pipLog("VideoPlayerPip: Retrying start for player=\(self.playerId ?? -1)")
      controller.startPictureInPicture()
    }
  }

  func finishStart(_ success: Bool) {
    observationToken?.invalidate(); observationToken = nil
    startTimeout?.cancel(); startTimeout = nil
    let completion = pipCompletion
    pipCompletion = nil
    completion?(success)
  }

  func pauseSource() {
    if let playerId { pausePlayer(playerId) }
    // Fallback if the source view disappeared; wrapper pause also clears its
    // playing intent, preventing buffering from restarting the source.
    pipPlayer?.pause()
  }

  func cleanupPipController() {
    observationToken?.invalidate(); observationToken = nil
    startTimeout?.cancel(); startTimeout = nil
    pipController?.delegate = nil
    pipController?.stopPictureInPicture()
    pipController = nil
    pipPlayer = nil
    playerId = nil
    isInPipMode = false
    restoring = false
    exitingFromApp = false
    resetting = false
    startingPip = false
    stoppingPip = false
  }

  func exitPipMode(completion: @escaping FlutterResult) {
    guard let pipController else {
      completion(false); return
    }
    // A lifecycle listener may request exit while the system is already
    // closing/restoring PiP. Keep the original reason and its restore event.
    if stoppingPip { completion(true); return }
    guard pipController.isPictureInPictureActive else { completion(false); return }
    exitingFromApp = true
    pipController.stopPictureInPicture()
    completion(true)
  }
}
#endif
