#include "include/video_player_custom/video_player_custom_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <memory>
#include <optional>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

// A compact overlay uses the existing Flutter window and playback texture.
// No second engine/player is created, so playback and position are preserved.
class VideoPlayerCustomPlugin : public flutter::Plugin {
 public:
  explicit VideoPlayerCustomPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), "video_player_pip",
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      const auto& method = call.method_name();
      if (method == "isPipSupported") {
        result->Success(EncodableValue(Window() != nullptr));
      } else if (method == "isInPipMode") {
        result->Success(EncodableValue(active_));
      } else if (method == "enterPipMode") {
        const auto* args = std::get_if<EncodableMap>(call.arguments());
        const auto width = ReadInt(args, "width", 360);
        const auto height = ReadInt(args, "height", 203);
        if (ReadInt(args, "playerId", -1) < 0 || width <= 0 || height <= 0) {
          result->Error("invalid_arguments", "A player and positive dimensions are required.");
          return;
        }
        result->Success(EncodableValue(Enter(width, height)));
      } else if (method == "exitPipMode" || method == "reset") {
        const bool exited = Exit(method == "exitPipMode");
        if (method == "reset") result->Success();
        else result->Success(EncodableValue(exited));
      } else {
        result->NotImplemented();
      }
    });
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM)
            -> std::optional<LRESULT> {
          if (active_ && hwnd == window_ && message == WM_CLOSE) {
            Exit(true);
            return 0;
          }
          if (active_ && hwnd == window_ && message == WM_SYSCOMMAND) {
            const auto command = wparam & 0xfff0;
            if (command == SC_CLOSE || command == SC_MAXIMIZE || command == SC_RESTORE) {
              Exit(true);
              return 0;
            }
          }
          return std::nullopt;
        });
  }

  ~VideoPlayerCustomPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    Exit(false, false);
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

 private:
  static int64_t ReadInt(const EncodableMap* args, const char* key, int64_t fallback) {
    if (!args) return fallback;
    const auto it = args->find(EncodableValue(key));
    if (it == args->end()) return fallback;
    if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
    if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
    return fallback;
  }

  HWND Window() const {
    auto* view = registrar_->GetView();
    return view ? GetAncestor(view->GetNativeWindow(), GA_ROOT) : nullptr;
  }

  bool Enter(int64_t width, int64_t height) {
    if (active_) return true;
    window_ = Window();
    if (!window_) return false;
    placement_.length = sizeof(placement_);
    if (!GetWindowPlacement(window_, &placement_)) return false;
    was_topmost_ = (GetWindowLongPtr(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor)) return false;
    const auto& work = monitor.rcWork;
    const int w = static_cast<int>(std::clamp<int64_t>(width, 160, std::max<LONG>(160, work.right - work.left)));
    const int h = static_cast<int>(std::clamp<int64_t>(height, 120, std::max<LONG>(120, work.bottom - work.top)));
    // Restore first when maximized. Only intercept system commands after entry.
    ShowWindow(window_, SW_RESTORE);
    if (!SetWindowPos(window_, HWND_TOPMOST,
                      std::max(work.left, work.right - w - 16),
                      std::max(work.top, work.bottom - h - 16), w, h,
                      SWP_SHOWWINDOW | SWP_NOACTIVATE)) {
      SetWindowPos(window_, was_topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST,
                   0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      SetWindowPlacement(window_, &placement_);
      return false;
    }
    active_ = true;
    channel_->InvokeMethod("pipModeChanged", std::make_unique<EncodableValue>(
        EncodableMap{{EncodableValue("isInPipMode"), EncodableValue(true)}}));
    return true;
  }

  bool Exit(bool restored, bool notify = true) {
    if (!active_) return false;
    active_ = false;
    if (IsWindow(window_)) {
      SetWindowPos(window_, was_topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST,
                   0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      SetWindowPlacement(window_, &placement_);
    }
    if (notify) {
      channel_->InvokeMethod(restored ? "onPipRestore" : "pipModeChanged",
          std::make_unique<EncodableValue>(EncodableMap{
              {EncodableValue("isInPipMode"), EncodableValue(false)}}));
    }
    return true;
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  int delegate_ = -1;
  HWND window_ = nullptr;
  WINDOWPLACEMENT placement_{};
  bool active_ = false;
  bool was_topmost_ = false;
};
}  // namespace

void VideoPlayerCustomPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(std::make_unique<VideoPlayerCustomPlugin>(windows_registrar));
}
