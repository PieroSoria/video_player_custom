cmake_minimum_required(VERSION 3.14)
project(video_player_custom LANGUAGES CXX)
set(PLUGIN_NAME "video_player_custom_plugin")
add_library(${PLUGIN_NAME} SHARED
  "video_player_custom_plugin.cpp"
  "wmf_video_player.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
# Windows Media Foundation (decode) + WASAPI (audio) + COM (PropVariant).
target_link_libraries(${PLUGIN_NAME} PRIVATE mfplat mfuuid mf mfreadwrite ole32)
set(video_player_custom_bundled_libraries "" PARENT_SCOPE)
