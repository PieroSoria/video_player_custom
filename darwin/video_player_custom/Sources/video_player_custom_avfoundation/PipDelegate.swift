#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import AVKit

extension VideoPlayerPipPlugin {
  public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard pipController === controller else { return }
    isInPipMode = true
    pipLog("VideoPlayerPip: PiP started player=\(playerId ?? -1)")
    sendToFlutter("pipModeChanged", arguments: ["isInPipMode": true])
    finishStart(true)
  }

  public func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
    guard pipController === controller else { return }
    stoppingPip = true
    if !exitingFromApp { pauseSource() }
    pipLog("VideoPlayerPip: PiP will stop player=\(playerId ?? -1) rate=\(pipPlayer?.rate ?? -1)")
  }

  public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    guard pipController === controller else { return }
    let shouldRestore = restoring && !exitingFromApp && !resetting
    let seconds = pipPlayer?.currentTime().seconds ?? 0
    if !exitingFromApp { pauseSource() }
    pipLog("VideoPlayerPip: PiP stopped player=\(playerId ?? -1) restore=\(shouldRestore) rate=\(pipPlayer?.rate ?? -1)")
    finishStart(false)
    cleanupPipController()
    // Exactly one terminal event, after the old player is paused. Flutter may
    // now reuse that controller or create a replacement without audio overlap.
    if shouldRestore {
      sendToFlutter("onPipRestore", arguments: ["positionMs": seconds.isFinite ? Int64(max(0, seconds) * 1000) : 0])
    } else {
      sendToFlutter("pipModeChanged", arguments: ["isInPipMode": false])
    }
  }

  public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                       failedToStartPictureInPictureWithError error: Error) {
    guard pipController === controller else { return }
    pipLog("VideoPlayerPip: Failed to start PiP: \(error.localizedDescription)")
    sendToFlutter("pipError", arguments: ["error": error.localizedDescription])
    finishStart(false)
    cleanupPipController()
  }

  public func pictureInPictureController(_ controller: AVPictureInPictureController,
                                       restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard pipController === controller, !resetting else { completionHandler(false); return }
    stoppingPip = true
    restoring = true
    if !exitingFromApp { pauseSource() }
    pipLog("VideoPlayerPip: Restore requested player=\(playerId ?? -1) rate=\(pipPlayer?.rate ?? -1)")
    // The layer already belongs to the source app. Complete AVKit's restore
    // first; didStop delivers the navigation event once PiP has released it.
    completionHandler(true)
  }
}
#endif
