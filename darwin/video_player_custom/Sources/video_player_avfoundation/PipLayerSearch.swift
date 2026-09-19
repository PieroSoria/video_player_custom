#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import AVKit

extension VideoPlayerPipPlugin {

  /**
   * Find the AVPlayerLayer for the specified player ID.
   * This searches through the view hierarchy to find the platform view created by video_player.
   */
  func findAVPlayerLayer(playerId: Int) -> AVPlayerLayer? {
    pipLog("VideoPlayerPip: Finding AVPlayerLayer for playerId: \(playerId)")
    // Use a more modern approach to get the active window
    let keyWindow = getKeyWindow()
    pipLog("VideoPlayerPip: keyWindow found: \(keyWindow != nil)")
    if let rootViewController = keyWindow?.rootViewController {
      pipLog("VideoPlayerPip: Starting search from rootViewController: \(type(of: rootViewController))")
      // Start with the root view and search recursively
      return findAVPlayerLayerInView(rootViewController.view, depth: 0)
    }
    pipLog("VideoPlayerPip: No rootViewController found")
    return nil
  }

  /**
   * Get the key window using a more modern approach that works on iOS 13+
   */
  func getKeyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      let scenes = UIApplication.shared.connectedScenes
        .filter { $0.activationState == .foregroundActive }
        .compactMap { $0 as? UIWindowScene }

      pipLog("VideoPlayerPip: Found \(scenes.count) active window scenes")

      if let windowScene = scenes.first {
        let windows = windowScene.windows.filter { $0.isKeyWindow }
        pipLog("VideoPlayerPip: Found \(windows.count) key windows in the first scene")
        return windows.first
      }
      return nil
    } else {
      let window = UIApplication.shared.keyWindow
      pipLog("VideoPlayerPip: Using legacy keyWindow approach: \(window != nil)")
      return window
    }
  }

  /**
   * Recursively search for an AVPlayerLayer in the view hierarchy.
   */
  func findAVPlayerLayerInView(_ view: UIView, depth: Int) -> AVPlayerLayer? {
    let indentation = String(repeating: "  ", count: depth)
    let className = NSStringFromClass(type(of: view))
    pipLog("\(indentation)VideoPlayerPip: Checking view: \(className)")

    // Check if this view's layer is an AVPlayerLayer
    if let playerLayer = view.layer as? AVPlayerLayer {
      pipLog("\(indentation)VideoPlayerPip: Found AVPlayerLayer directly as view's layer")
      // Check if the player is set
      if let player = playerLayer.player {
        pipLog("\(indentation)VideoPlayerPip: AVPlayerLayer has player: \(player)")
        return playerLayer
      } else {
        pipLog("\(indentation)VideoPlayerPip: AVPlayerLayer has no player set")
      }
    }

    // Check for class name matching FVPPlayerView which has an AVPlayerLayer as its layer
    if className.contains("FVPPlayerView") {
      pipLog("\(indentation)VideoPlayerPip: Found FVPPlayerView")
      if let playerLayer = view.layer as? AVPlayerLayer {
        pipLog("\(indentation)VideoPlayerPip: FVPPlayerView's layer is AVPlayerLayer")
        if let player = playerLayer.player {
          pipLog("\(indentation)VideoPlayerPip: FVPPlayerView's AVPlayerLayer has player: \(player)")
        } else {
          pipLog("\(indentation)VideoPlayerPip: FVPPlayerView's AVPlayerLayer has no player set")
        }
        return playerLayer
      } else {
        pipLog("\(indentation)VideoPlayerPip: FVPPlayerView's layer is not AVPlayerLayer: \(type(of: view.layer))")
      }
    }

    // Check sublayers directly in case AVPlayerLayer is a sublayer
    if let sublayers = view.layer.sublayers {
      pipLog("\(indentation)VideoPlayerPip: Checking \(sublayers.count) sublayers")
      for sublayer in sublayers {
        if let playerLayer = sublayer as? AVPlayerLayer {
          pipLog("\(indentation)VideoPlayerPip: Found AVPlayerLayer as a sublayer")
          if let player = playerLayer.player {
            pipLog("\(indentation)VideoPlayerPip: Sublayer AVPlayerLayer has player: \(player)")
            return playerLayer
          } else {
            pipLog("\(indentation)VideoPlayerPip: Sublayer AVPlayerLayer has no player set")
          }
        }
      }
    }

    // Recursively check subviews
    pipLog("\(indentation)VideoPlayerPip: Checking \(view.subviews.count) subviews")
    for subview in view.subviews {
      if let layer = findAVPlayerLayerInView(subview, depth: depth + 1) {
        return layer
      }
    }

    return nil
  }
}

#endif
