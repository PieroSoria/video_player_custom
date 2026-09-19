import Flutter
import UIKit
import AVFoundation
import AVKit

extension VideoPlayerPipPlugin {

  /// Registers observers for app lifecycle so PiP can continue in background.
  func setupLifecycleObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  @objc func applicationDidEnterBackground() {
    pipLog("VideoPlayerPip: App entered background, isInPipMode: \(isInPipMode)")
    guard isInPipMode else { return }

    // The audio session is configured and activated once, at PiP start
    // (`enterPipMode`). We deliberately do NOT re-activate it here: repeatedly
    // calling `setActive(true)` on every background/foreground transition added
    // state and races without benefit. Background playback is granted by the
    // `UIBackgroundModes` (audio + video) declared in Info.plist.
    if let player = pipPlayer {
      let reason = String(describing: player.reasonForWaitingToPlay ?? .noItemToPlay)
      pipLog("VideoPlayerPip: BG player state: status=\(player.status.rawValue) tcs=\(player.timeControlStatus.rawValue) rate=\(player.rate) reason=\(reason) error=\(player.error?.localizedDescription ?? "none")")
    }
  }

  @objc func applicationWillEnterForeground() {
    pipLog("VideoPlayerPip: App will enter foreground, isInPipMode: \(isInPipMode)")
  }
}
