#if os(iOS)
import Flutter
import UIKit
import AVFoundation
import AVKit

extension VideoPlayerPipPlugin {

  // MARK: - Enter PiP

  func enterPipMode(playerId: Int, completion: @escaping FlutterResult) {
    pipLog("VideoPlayerPip: enterPipMode called for playerId: \(playerId)")
    if !isPipSupported() {
      pipLog("VideoPlayerPip: PiP not supported by the device")
      completion(false)
      return
    }

    // Resolve only this engine's requested inline player. A hierarchy search
    // could select another video when multiple players are visible.
    let playerLayer = playerLayerProvider(Int64(playerId))

    guard let playerLayer else {
      pipLog("VideoPlayerPip: Could not find player layer for ID: \(playerId)")
      completion(false)
      return
    }

    pipLog("VideoPlayerPip: Found AVPlayerLayer: \(playerLayer)")

    // Check if player is ready
    if let player = playerLayer.player {
      pipLog("VideoPlayerPip: Player status: \(player.status.rawValue), currentItem: \(player.currentItem != nil ? "exists" : "nil"), error: \(player.error?.localizedDescription ?? "none")")

      // Store completion to call when PiP actually starts/fails
      self.pipCompletion = completion

      // Configure audio session for PiP (required for video playback in background)
      // video_player may have already configured it, so just ensure it's active
      do {
        let audioSession = AVAudioSession.sharedInstance()
        // Only set category if not already set to playback
        if audioSession.category != .playback {
          try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
        }
        if !audioSession.isOtherAudioPlaying {
          try audioSession.setActive(true)
        }
        pipLog("VideoPlayerPip: Audio session ready for PiP (category: \(audioSession.category.rawValue))")
      } catch {
        pipLog("VideoPlayerPip: Audio session setup note: \(error)")
        // Non-fatal, continue anyway
      }

      // Ensure the player is playing
      if player.timeControlStatus != .playing {
        pipLog("VideoPlayerPip: Player is not currently playing, trying to play")
        player.play()
      }

      // Wait a moment to ensure player is properly prepared
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.continueEnterPipMode(playerLayer: playerLayer)
      }
    } else {
      pipLog("VideoPlayerPip: AVPlayerLayer has no player set")
      completion(false)
    }
  }

  func continueEnterPipMode(playerLayer: AVPlayerLayer) {
    // Create and configure the PiP controller
    if #available(iOS 14.0, *) {
      pipLog("VideoPlayerPip: Creating AVPictureInPictureController with playerLayer")

      // Check if we can create a PiP controller with this layer
      if AVPictureInPictureController.isPictureInPictureSupported() && playerLayer.player != nil {
        // Clean up any existing controller and observations
        cleanupPipController()

        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipPlayer = playerLayer.player
        pipController?.delegate = self

        // Enable PiP to start from inline (foreground)
        if #available(iOS 14.2, *) {
          pipLog("VideoPlayerPip: Setting canStartPictureInPictureAutomaticallyFromInline to true")
          pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }

        // Allow PiP during interactive playback
        if #available(iOS 15.0, *) {
          pipLog("VideoPlayerPip: Setting requiresLinearPlayback to false")
          pipController?.requiresLinearPlayback = false
        }

        pipLog("VideoPlayerPip: PiP controller created successfully: \(String(describing: pipController))")

        // Set up observation for the possible PiP state
        if #available(iOS 14.0, *) {
          observationToken = pipController?.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] (controller, change) in
            guard let self = self, let newValue = change.newValue else { return }
            pipLog("VideoPlayerPip: isPictureInPictureActive changed to \(newValue)")
            self.isInPipMode = newValue
            self.sendToFlutter("pipModeChanged", arguments: ["isInPipMode": newValue])
          }
        }

        // If the player layer is removed from the view hierarchy (screen disposed
        // or navigated away), the app is responsible for releasing PiP via the
        // explicit `reset()` call (typically from the Flutter widget's dispose).
        // We intentionally do NOT observe `superlayer` here: relying on it caused
        // redundant state and interfered with legitimate background PiP sessions.

        // Ensure player is actually playing before starting PiP
        if let player = playerLayer.player {
          if player.timeControlStatus == .playing {
            pipLog("VideoPlayerPip: Player is already playing, starting PiP immediately")
            startPip()
          } else {
            pipLog("VideoPlayerPip: Player is not playing (status: \(player.timeControlStatus.rawValue)), waiting for playback...")
            // Observe the player's timeControlStatus to wait for it to start playing
            var statusObservation: NSKeyValueObservation?
            statusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, change in
              guard let self = self else { return }
              if player.timeControlStatus == .playing {
                pipLog("VideoPlayerPip: Player started playing, starting PiP")
                statusObservation?.invalidate()
                statusObservation = nil
                self.startPip()
              }
            }
            // Also ensure play is called
            player.play()

            // Fallback timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
              guard let self = self else { return }
              if statusObservation != nil {
                statusObservation?.invalidate()
                statusObservation = nil
                if player.timeControlStatus != .playing {
                  pipLog("VideoPlayerPip: Timeout waiting for player to start, attempting PiP anyway")
                  self.startPip()
                }
              }
            }
          }
        } else {
          pipLog("VideoPlayerPip: No player available, cannot start PiP")
          pipCompletion?(false)
          pipCompletion = nil
        }
      } else {
        pipLog("VideoPlayerPip: Cannot create PiP controller - either not supported or player is nil")
        pipCompletion?(false)
        pipCompletion = nil
      }
    } else {
      pipLog("VideoPlayerPip: iOS version < 14.0, cannot create PiP controller")
      pipCompletion?(false)
      pipCompletion = nil
    }
  }

  func startPip() {
    guard let pipController = pipController else {
      pipLog("VideoPlayerPip: No pipController available to start PiP")
      pipCompletion?(false)
      pipCompletion = nil
      return
    }

    pipLog("VideoPlayerPip: Attempting to start PiP, isPictureInPicturePossible: \(pipController.isPictureInPicturePossible), delegate: \(String(describing: pipController.delegate))")

    if #available(iOS 15.0, *) {
      // On iOS 15+, we can try a slightly more direct approach
      pipLog("VideoPlayerPip: Calling startPictureInPicture() on iOS 15+")
      pipController.startPictureInPicture()

      // Also try after a short delay as a fallback
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, !(self.pipController?.isPictureInPictureActive ?? false) else { return }
        pipLog("VideoPlayerPip: Trying to start PiP again after delay (iOS 15+)")
        self.pipController?.startPictureInPicture()
      }

      // Add a timeout to handle case where neither success nor failure is called
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard let self = self else { return }
        if !(self.pipController?.isPictureInPictureActive ?? false) && self.pipCompletion != nil {
          pipLog("VideoPlayerPip: Timeout - PiP didn't start or fail after 5s, treating as failure")
          self.pipCompletion?(false)
          self.pipCompletion = nil
        }
      }

    } else {
      // On iOS 14, just use the regular API
      pipLog("VideoPlayerPip: Calling startPictureInPicture() on iOS 14")
      pipController.startPictureInPicture()

      // Add a timeout for iOS 14 too
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard let self = self else { return }
        if !(self.pipController?.isPictureInPictureActive ?? false) && self.pipCompletion != nil {
          pipLog("VideoPlayerPip: Timeout - PiP didn't start or fail after 5s, treating as failure")
          self.pipCompletion?(false)
          self.pipCompletion = nil
        }
      }
    }
  }

  func cleanupPipController() {
    observationToken?.invalidate()
    observationToken = nil
    pipPlayer = nil

    if isInPipMode && pipController != nil {
      pipController?.stopPictureInPicture()
    }

    pipController = nil
  }

  func exitPipMode(completion: @escaping FlutterResult) {
    pipLog("VideoPlayerPip: exitPipMode called, isInPipMode: \(isInPipMode), pipController: \(String(describing: pipController))")
    if isInPipMode, pipController != nil {
      pipLog("VideoPlayerPip: Stopping picture-in-picture")
      pipController?.stopPictureInPicture()
      completion(true)
    } else {
      pipLog("VideoPlayerPip: Cannot stop PiP - either not in PiP mode or controller is nil")
      completion(false)
    }
  }
}

#endif
