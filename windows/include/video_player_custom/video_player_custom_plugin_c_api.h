#ifndef FLUTTER_PLUGIN_VIDEO_PLAYER_CUSTOM_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_VIDEO_PLAYER_CUSTOM_PLUGIN_C_API_H_
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define VIDEO_PLAYER_CUSTOM_EXPORT __declspec(dllexport)
#else
#define VIDEO_PLAYER_CUSTOM_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
VIDEO_PLAYER_CUSTOM_EXPORT void VideoPlayerCustomPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
#endif
