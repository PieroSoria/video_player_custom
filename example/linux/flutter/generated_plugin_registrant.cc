//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <video_player_custom/video_player_custom_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) video_player_custom_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "VideoPlayerCustomPlugin");
  video_player_custom_plugin_register_with_registrar(video_player_custom_registrar);
}
