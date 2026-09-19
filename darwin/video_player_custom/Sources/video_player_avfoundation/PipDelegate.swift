#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import AVKit

extension VideoPlayerPipPlugin {

  // MARK: - AVPictureInPictureControllerDelegate

  public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipLog("VideoPlayerPip: PiP started successfully")
    isInPipMode = true
    sendToFlutter("pipModeChanged", arguments: ["isInPipMode": true])
    pipCompletion?(true)
    pipCompletion = nil
  }

  public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipLog("VideoPlayerPip: PiP stopped")
    isInPipMode = false
    // NOTE: we intentionally do NOT nil `pipPlayer` here. We keep the strong
    // reference so a later `reset()` can find the AVPlayer and force-stop it
    // (pause + clear currentItem), killing any residual audio/video. It is
    // cleared later by `reset()` / `cleanupPipController()` or replaced when a
    // new video enters PiP.
    sendToFlutter("pipModeChanged", arguments: ["isInPipMode": false])
    // Explicitly release the controller when PiP is stopped
    if #available(iOS 14.0, *) {
        if self.pipController == pictureInPictureController {
            pipLog("VideoPlayerPip: Releasing pipController reference")
            self.pipController = nil
        } else {
            pipLog("VideoPlayerPip: Stopped PiP controller doesn't match current pipController")
        }
    } else {
        if self.pipController === pictureInPictureController {
            pipLog("VideoPlayerPip: Releasing pipController reference (using identity check)")
            self.pipController = nil
        } else {
            pipLog("VideoPlayerPip: Stopped PiP controller doesn't match current pipController (using identity check)")
        }
    }
  }

  public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    pipLog("VideoPlayerPip: Failed to start PiP: \(error.localizedDescription)")
    pipLog("VideoPlayerPip: Error details: \(error)")
    sendToFlutter("pipError", arguments: ["error": error.localizedDescription])
    pipCompletion?(false)
    pipCompletion = nil
  }

  public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipLog("VideoPlayerPip: PiP will start - delegate called")
  }

  public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipLog("VideoPlayerPip: PiP will stop")
  }

  /// Called when the user taps the PiP window's "restore/expand" button. We notify
  /// Flutter so the app can navigate back to the full-screen video, then signal
  /// the system that the UI has been restored.
  ///
  /// The current AVPlayer position is sent along so the app can resume playback
  /// exactly where it was left (the retained [pipPlayer] is the same instance
  /// video_player created, so its clock is authoritative).
  public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                         restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    pipLog("VideoPlayerPip: Restoring UI from PiP (user tapped expand button)")
    let positionMs = self.pipPlayer?.currentItem?.currentTime() ?? .zero
    let positionMsInt = Int64(positionMs.seconds * 1000)
    sendToFlutter("onPipRestore", arguments: ["positionMs": positionMsInt])
    completionHandler(true)
  }
}

#endif
