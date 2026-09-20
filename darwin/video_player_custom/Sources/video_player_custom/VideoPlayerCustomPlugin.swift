import Foundation
import video_player_custom_avfoundation
#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import FlutterMacOS
#endif

public class VideoPlayerCustomPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    VideoPlayerPlugin.register(with: registrar)
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "video_player_custom", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(VideoPlayerCustomPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "getPlatformVersion" else {
      result(FlutterMethodNotImplemented)
      return
    }
    #if os(iOS)
    result("iOS " + UIDevice.current.systemVersion)
    #else
    result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    #endif
  }
}
