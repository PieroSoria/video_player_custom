#ifndef FLUTTER_PLUGIN_VIDEO_PLAYER_CUSTOM_PLUGIN_H_
#define FLUTTER_PLUGIN_VIDEO_PLAYER_CUSTOM_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace video_player_custom {

class VideoPlayerCustomPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  VideoPlayerCustomPlugin();

  virtual ~VideoPlayerCustomPlugin();

  // Disallow copy and assign.
  VideoPlayerCustomPlugin(const VideoPlayerCustomPlugin&) = delete;
  VideoPlayerCustomPlugin& operator=(const VideoPlayerCustomPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace video_player_custom

#endif  // FLUTTER_PLUGIN_VIDEO_PLAYER_CUSTOM_PLUGIN_H_
