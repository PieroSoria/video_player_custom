cmake_minimum_required(VERSION 3.10)
project(video_player_custom LANGUAGES CXX)
set(PLUGIN_NAME "video_player_custom_plugin")
add_library(${PLUGIN_NAME} SHARED
  "gst_video_player.cc"
  "video_player_custom_plugin.cc")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
# GStreamer core (playbin, bus, queries) + app (appsink pull API).
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET gstreamer-1.0)
pkg_check_modules(GSTAPP REQUIRED IMPORTED_TARGET gstreamer-app-1.0)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GST PkgConfig::GSTAPP)
# playbin/autoaudiosink/videoconvert/videoscale ship at runtime with
# gst-plugins-base; nothing needs to be bundled alongside the plugin.
set(video_player_custom_bundled_libraries "" PARENT_SCOPE)