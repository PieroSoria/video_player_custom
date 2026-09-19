#include "include/video_player_custom/video_player_custom_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "video_player_custom_plugin.h"

void VideoPlayerCustomPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  video_player_custom::VideoPlayerCustomPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
