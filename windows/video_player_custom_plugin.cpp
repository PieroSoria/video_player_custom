#include "include/video_player_custom/video_player_custom_plugin_c_api.h"

#include "desktop_task_poster.h"
#include "wmf_video_player.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <algorithm>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// ---------------------------------------------------------------------------
// Platform-thread task poster.
// ---------------------------------------------------------------------------

// Marshals tasks onto the Flutter platform thread using a message-only window.
// The player's pump thread posts messages here; the platform thread drains them
// in its window loop, where channel and texture calls are allowed.
class WindowsTaskPoster : public video_player_custom::TaskPoster {
 public:
  WindowsTaskPoster() {
    constexpr const wchar_t kClassName[] = L"VideoPlayerCustom_TaskPoster";
    WNDCLASS wc = {};
    wc.lpfnWndProc = &WindowsTaskPoster::WindowProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.lpszClassName = kClassName;
    if (RegisterClass(&wc) == 0 &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return;
    }
    message_ = RegisterWindowMessage(L"VideoPlayerCustom_PostPlatformTask");
    window_ = CreateWindowEx(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                             nullptr, wc.hInstance, this);
    if (window_) {
      SetWindowLongPtr(window_, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(this));
    }
  }

  ~WindowsTaskPoster() override {
    std::deque<std::function<void()>> leftover;
    if (!window_) return;
    closed_ = true;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      leftover.swap(tasks_);
    }
    DestroyWindow(window_);
    window_ = nullptr;
    // Drain on the (platform) thread destroying the poster.
    for (auto& task : leftover) task();
  }

  void Post(std::function<void()> task) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) return;
      tasks_.push_back(std::move(task));
    }
    if (window_) {
      PostMessage(window_, message_, 0, 0);
    }
  }

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    auto* self = reinterpret_cast<WindowsTaskPoster*>(
        GetWindowLongPtr(window, GWLP_USERDATA));
    if (self && message == self->message_) {
      self->RunPending();
      return 0;
    }
    return DefWindowProc(window, message, wparam, lparam);
  }

  void RunPending() {
    std::deque<std::function<void()>> pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pending.swap(tasks_);
    }
    for (auto& task : pending) {
      task();
    }
  }

  HWND window_ = nullptr;
  UINT message_ = WM_APP + 0x41;
  std::mutex mutex_;
  std::deque<std::function<void()>> tasks_;
  bool closed_ = false;
};

// ---------------------------------------------------------------------------
// Shared argument readers.
// ---------------------------------------------------------------------------

int64_t ReadInt(const EncodableValue* args, const char* key, int64_t fallback) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) return fallback;
  const auto& map = std::get<EncodableMap>(*args);
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  return fallback;
}

std::string ReadString(const EncodableValue* args, const char* key) {
  if (!args || !std::holds_alternative<EncodableMap>(*args))
    return std::string();
  const auto& map = std::get<EncodableMap>(*args);
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return std::string();
  if (const auto* value = std::get_if<std::string>(&it->second)) return *value;
  return std::string();
}

bool ReadBool(const EncodableValue* args, const char* key, bool fallback) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) return fallback;
  const auto& map = std::get<EncodableMap>(*args);
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

double ReadDouble(const EncodableValue* args, const char* key, double fallback) {
  if (!args || !std::holds_alternative<EncodableMap>(*args)) return fallback;
  const auto& map = std::get<EncodableMap>(*args);
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second))
    return static_cast<double>(*value);
  if (const auto* value = std::get_if<int64_t>(&it->second))
    return static_cast<double>(*value);
  return fallback;
}

// ---------------------------------------------------------------------------
// Existing compact (PiP) overlay plugin.
// ---------------------------------------------------------------------------

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
        const auto width = ReadInt(call.arguments(), "width", 360);
        const auto height = ReadInt(call.arguments(), "height", 203);
        if (ReadInt(call.arguments(), "playerId", -1) < 0 || width <= 0 ||
            height <= 0) {
          result->Error("invalid_arguments",
                        "A player and positive dimensions are required.");
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
            if (command == SC_CLOSE || command == SC_MAXIMIZE ||
                command == SC_RESTORE) {
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
    if (!GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      return false;
    }
    const auto& work = monitor.rcWork;
    const int w = static_cast<int>(std::clamp<int64_t>(
        width, 160, std::max<LONG>(160, work.right - work.left)));
    const int h = static_cast<int>(std::clamp<int64_t>(
        height, 120, std::max<LONG>(120, work.bottom - work.top)));
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
    channel_->InvokeMethod(
        "pipModeChanged",
        std::make_unique<EncodableValue>(EncodableMap{
            {EncodableValue("isInPipMode"), EncodableValue(true)}}));
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
      channel_->InvokeMethod(
          restored ? "onPipRestore" : "pipModeChanged",
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

// ---------------------------------------------------------------------------
// Native desktop video backend (Windows Media Foundation).
// ---------------------------------------------------------------------------

// Serializes [video_player_custom::PlayerEvent]s for the per-player event
// channel. The first event (initialized) is cached until the Flutter side
// subscribes, which happens asynchronously after `create` returns.
class DesktopPlayerState {
 public:
  void Attach(std::unique_ptr<flutter::EventSink<EncodableValue>> sink) {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_ = std::move(sink);
    active_ = true;
    if (cached_initialized_) {
      sink_->Success(*cached_initialized_);
      cached_initialized_.reset();
    }
  }

  void Detach() {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_.reset();
    active_ = false;
  }

  void Emit(const video_player_custom::PlayerEvent& event) {
    EncodableMap map;
    switch (event.type) {
      case video_player_custom::PlayerEvent::Type::kInitialized:
        map[EncodableValue("event")] = EncodableValue("initialized");
        map[EncodableValue("duration")] = EncodableValue(event.duration_ms);
        map[EncodableValue("width")] = EncodableValue(event.width);
        map[EncodableValue("height")] = EncodableValue(event.height);
        break;
      case video_player_custom::PlayerEvent::Type::kCompleted:
        map[EncodableValue("event")] = EncodableValue("completed");
        break;
      case video_player_custom::PlayerEvent::Type::kBufferingStart:
        map[EncodableValue("event")] = EncodableValue("bufferingStart");
        break;
      case video_player_custom::PlayerEvent::Type::kBufferingEnd:
        map[EncodableValue("event")] = EncodableValue("bufferingEnd");
        break;
      case video_player_custom::PlayerEvent::Type::kIsPlayingStateUpdate:
        map[EncodableValue("event")] = EncodableValue("isPlayingStateUpdate");
        map[EncodableValue("isPlaying")] = EncodableValue(event.is_playing);
        break;
      case video_player_custom::PlayerEvent::Type::kError:
        map[EncodableValue("event")] = EncodableValue("error");
        map[EncodableValue("message")] = EncodableValue(event.message);
        break;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (active_ && sink_) {
      sink_->Success(map);
      return;
    }
    if (event.type == video_player_custom::PlayerEvent::Type::kInitialized) {
      cached_initialized_ = std::move(map);
    }
  }

 private:
  std::mutex mutex_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
  bool active_ = false;
  std::optional<EncodableMap> cached_initialized_;
};

class DesktopEventStreamHandler
    : public flutter::StreamHandler<EncodableValue> {
 public:
  explicit DesktopEventStreamHandler(
      std::shared_ptr<DesktopPlayerState> state)
      : state_(std::move(state)) {}

  std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> OnListenInternal(
      const EncodableValue* /*arguments*/,
      std::unique_ptr<flutter::EventSink<EncodableValue>>&& events) override {
    state_->Attach(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
  OnCancelInternal(const EncodableValue* /*arguments*/) override {
    state_->Detach();
    return nullptr;
  }

 private:
  std::shared_ptr<DesktopPlayerState> state_;
};

struct DesktopPlayerEntry {
  std::shared_ptr<video_player_custom::WmfVideoPlayer> player;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
};

class DesktopVideoPlayerPlugin : public flutter::Plugin {
 public:
  explicit DesktopVideoPlayerPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        // The registrar owns the TextureRegistrar; keep a borrowed shared_ptr.
        textures_(registrar->texture_registrar(),
                  [](flutter::TextureRegistrar*) {}),
        poster_(std::make_shared<WindowsTaskPoster>()),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), "video_player_custom/desktop",
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleMethodCall(call, std::move(result));
    });
  }

  ~DesktopVideoPlayerPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    std::lock_guard<std::mutex> lock(players_mutex_);
    for (auto& [id, entry] : players_) {
      entry->player->Dispose();
      textures_->UnregisterTexture(entry->player->texture_id(), nullptr);
      if (entry->events) {
        entry->events->SetStreamHandler(nullptr);
      }
    }
    players_.clear();
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();

    if (method == "create") {
      Create(call, std::move(result));
      return;
    }

    const int64_t id = ReadInt(call.arguments(), "playerId", -1);

    if (method == "dispose") {
      DestroyPlayer(id);
      result->Success();
      return;
    }

    std::shared_ptr<video_player_custom::WmfVideoPlayer> player;
    {
      std::lock_guard<std::mutex> lock(players_mutex_);
      const auto it = players_.find(id);
      if (it == players_.end()) {
        result->Error("player_not_found", "No player with the given ID.");
        return;
      }
      player = it->second->player;
    }

    if (method == "play") {
      player->Play();
      result->Success();
    } else if (method == "pause") {
      player->Pause();
      result->Success();
    } else if (method == "seekTo") {
      player->SeekTo(ReadInt(call.arguments(), "positionMs", 0));
      result->Success();
    } else if (method == "setLooping") {
      player->SetLooping(ReadBool(call.arguments(), "looping", false));
      result->Success();
    } else if (method == "setVolume") {
      player->SetVolume(
          static_cast<float>(ReadDouble(call.arguments(), "volume", 1.0)));
      result->Success();
    } else if (method == "setPlaybackSpeed") {
      player->SetPlaybackSpeed(
          static_cast<float>(ReadDouble(call.arguments(), "speed", 1.0)));
      result->Success();
    } else if (method == "getPosition") {
      result->Success(EncodableValue(player->GetPositionMs()));
    } else if (method == "getBufferedPosition") {
      result->Success(EncodableValue(player->GetBufferedPositionMs()));
    } else {
      result->NotImplemented();
    }
  }

  void Create(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const std::string uri = ReadString(call.arguments(), "uri");
    if (uri.empty()) {
      result->Error("invalid_arguments", "A non-empty uri is required.");
      return;
    }

    const int64_t player_id = next_player_id_++;
    const std::string channel_name =
        "video_player_custom/desktop/events/" + std::to_string(player_id);

    auto state = std::make_shared<DesktopPlayerState>();
    auto entry = std::make_unique<DesktopPlayerEntry>();
    entry->events = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar_->messenger(), channel_name,
        &flutter::StandardMethodCodec::GetInstance());
    // The EventChannel takes ownership of the handler, so it is not stored in
    // the entry; the shared state keeps everything alive.
    entry->events->SetStreamHandler(
        std::make_unique<DesktopEventStreamHandler>(state));

    entry->player = std::make_shared<video_player_custom::WmfVideoPlayer>(
        textures_, poster_,
        [state](const video_player_custom::PlayerEvent& event) {
          state->Emit(event);
        });

    std::string error;
    if (!entry->player->Initialize(uri, &error)) {
      entry->player->Dispose();
      if (entry->player->texture_id() >= 0) {
        textures_->UnregisterTexture(entry->player->texture_id(), nullptr);
      }
      entry->events->SetStreamHandler(nullptr);
      result->Error("video_error", error);
      return;
    }

    const int64_t texture_id = entry->player->texture_id();
    std::lock_guard<std::mutex> lock(players_mutex_);
    players_[player_id] = std::move(entry);

    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("playerId"), EncodableValue(player_id)},
        {EncodableValue("textureId"), EncodableValue(texture_id)},
    }));
  }

  void DestroyPlayer(int64_t id) {
    std::shared_ptr<video_player_custom::WmfVideoPlayer> player;
    std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
    {
      std::lock_guard<std::mutex> lock(players_mutex_);
      const auto it = players_.find(id);
      if (it == players_.end()) return;
      player = it->second->player;
      events = std::move(it->second->events);
      players_.erase(it);
    }
    if (events) {
      events->SetStreamHandler(nullptr);
    }
    player->Dispose();
    // Keep the player (and its pixel buffer / copy callback) alive until the
    // engine has finished releasing the texture.
    textures_->UnregisterTexture(player->texture_id(),
                                 [player]() { (void)player; });
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<flutter::TextureRegistrar> textures_;
  std::shared_ptr<video_player_custom::TaskPoster> poster_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::mutex players_mutex_;
  std::map<int64_t, std::unique_ptr<DesktopPlayerEntry>> players_;
  int64_t next_player_id_ = 1;
};

}  // namespace

void VideoPlayerCustomPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(
      std::make_unique<VideoPlayerCustomPlugin>(windows_registrar));
  windows_registrar->AddPlugin(
      std::make_unique<DesktopVideoPlayerPlugin>(windows_registrar));
}