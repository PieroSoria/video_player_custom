#include "include/video_player_custom/video_player_custom_plugin_c_api.h"

#include "desktop_task_poster.h"
#include "wmf_video_player.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <windowsx.h>

#include <algorithm>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

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
// Native picture-in-picture window.
// ---------------------------------------------------------------------------

// Borderless, always-on-top window that renders the player's frames directly
// (StretchDIBits), completely independent of the Flutter window. Dragging the
// top band moves it; clicking the video toggles play/pause; the close button
// hides it and lets Dart leave PiP mode.
class PipWindow {
 public:
  // The window is created and destroyed on the platform thread (channel
  // handlers), so the WndProc only ever runs on that same thread.
  PipWindow() = default;

  ~PipWindow() {
    if (window_) {
      DestroyWindow(window_);  // WM_DESTROY clears `window_`.
    }
  }

  void set_on_close(std::function<void()> on_close) {
    on_close_ = std::move(on_close);
  }

  void set_player(std::shared_ptr<video_player_custom::WmfVideoPlayer> player) {
    player_ = std::move(player);
  }

  bool Create(int64_t width, int64_t height) {
    if (window_) return true;
    const HINSTANCE instance = GetModuleHandle(nullptr);
    if (!registered_) {
      WNDCLASS wc = {};
      wc.style = CS_HREDRAW | CS_VREDRAW;
      wc.lpfnWndProc = &PipWindow::WindowProc;
      wc.hInstance = instance;
      wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
      wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
      wc.lpszClassName = kClassName;
      if (!RegisterClass(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return false;
      }
      registered_ = true;
    }
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!GetMonitorInfo(
            MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY),
            &monitor)) {
      return false;
    }
    const RECT& work = monitor.rcWork;
    const int w = static_cast<int>(std::clamp<int64_t>(
        width, 160, std::max<LONG>(160, work.right - work.left)));
    const int h = static_cast<int>(std::clamp<int64_t>(
        height, 120, std::max<LONG>(120, work.bottom - work.top)));
    HWND hwnd = CreateWindowEx(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName,
        L"Video Player (PiP)", WS_POPUP, work.right - w - 16,
        work.bottom - h - 16, w, h, nullptr, nullptr, instance, this);
    if (!hwnd) {
      return false;
    }
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    window_ = hwnd;
    last_generation_ = -1;
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    SetTimer(hwnd, kRenderTimerId, kRenderIntervalMs, nullptr);
    return true;
  }

  void Close() {
    if (!window_) {
      return;
    }
    DestroyWindow(window_);
  }

 private:
  static constexpr UINT kRenderTimerId = 0x5049;
  static constexpr UINT kRenderIntervalMs = 16;
  static constexpr int kDragBandPx = 28;
  static constexpr int kCloseButtonPx = 28;
  static constexpr const wchar_t kClassName[] =
      L"VideoPlayerCustom_PipWindow";

  std::shared_ptr<video_player_custom::WmfVideoPlayer> Player() const {
    return player_;
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    auto* self = reinterpret_cast<PipWindow*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (!self) {
      return DefWindowProc(hwnd, message, wparam, lparam);
    }
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }

  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
      case WM_NCHITTEST:
        return OnHitTest(hwnd, lparam);
      case WM_LBUTTONDOWN:
        TogglePlayPause();
        return 0;
      case WM_TIMER:
        RefreshIfChanged();
        return 0;
      case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        Paint(ps.hdc);
        EndPaint(hwnd, &ps);
        return 0;
      }
      case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
      case WM_DESTROY:
        KillTimer(hwnd, kRenderTimerId);
        window_ = nullptr;
        if (on_close_) {
          on_close_();
        }
        return 0;
    }
    return DefWindowProc(hwnd, message, wparam, lparam);
  }

  LRESULT OnHitTest(HWND hwnd, LPARAM lparam) {
    POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(hwnd, &pt);
    if (pt.y >= 0 && pt.y < kDragBandPx) {
      RECT rc;
      GetClientRect(hwnd, &rc);
      if (pt.x >= rc.right - kCloseButtonPx) {
        return HTCLOSE;
      }
      return HTCAPTION;
    }
    return HTCLIENT;
  }

  void TogglePlayPause() {
    const auto player = Player();
    if (!player) {
      return;
    }
    if (player->IsPlaying()) {
      player->Pause();
    } else {
      player->Play();
    }
  }

  void RefreshIfChanged() {
    const auto player = Player();
    if (!player) {
      return;
    }
    const int64_t generation = player->frame_generation();
    if (generation == last_generation_) {
      return;
    }
    last_generation_ = generation;
    InvalidateRect(window_, nullptr, FALSE);
  }

  void Paint(HDC dc) const {
    RECT rc;
    GetClientRect(window_, &rc);
    FillRect(dc, &rc, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    if (rc.right <= rc.left || rc.bottom <= rc.top) {
      return;
    }
    const auto player = Player();
    if (!player) {
      return;
    }
    int64_t width = 0;
    int64_t height = 0;
    int64_t stride = 0;
    std::vector<uint8_t> data;
    if (!player->CopyCurrentFrame(&data, &width, &height, &stride) ||
        width <= 0 || height <= 0) {
      return;
    }
    int draw_w;
    int draw_h;
    const double frame_aspect = static_cast<double>(width) / height;
    const double client_aspect =
        static_cast<double>(rc.right - rc.left) / (rc.bottom - rc.top);
    if (frame_aspect > client_aspect) {
      draw_w = rc.right - rc.left;
      draw_h = static_cast<int>(draw_w / frame_aspect);
    } else {
      draw_h = rc.bottom - rc.top;
      draw_w = static_cast<int>(draw_h * frame_aspect);
    }
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = static_cast<LONG>(width);
    bi.bmiHeader.biHeight = -static_cast<LONG>(height);  // top-down rows
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    StretchDIBits(dc, rc.left + (rc.right - rc.left - draw_w) / 2,
                  rc.top + (rc.bottom - rc.top - draw_h) / 2, draw_w, draw_h,
                  0, 0, static_cast<int>(width), static_cast<int>(height),
                  data.data(), &bi, DIB_RGB_COLORS, SRCCOPY);
  }

  std::shared_ptr<video_player_custom::WmfVideoPlayer> player_;
  std::function<void()> on_close_;
  HWND window_ = nullptr;
  bool registered_ = false;
  int64_t last_generation_ = -1;
};

// ---------------------------------------------------------------------------
// Picture-in-picture plugin channel (video_player_pip).
// ---------------------------------------------------------------------------

// Ties the native PiP window to Dart. The PiP window renders the player's
// frames itself, so the app's own window and UI keep running untouched.
using PlayerResolver = std::function<
    std::shared_ptr<video_player_custom::WmfVideoPlayer>(int64_t player_id)>;

class VideoPlayerCustomPlugin : public flutter::Plugin {
 public:
  explicit VideoPlayerCustomPlugin(flutter::PluginRegistrarWindows* registrar,
                                   PlayerResolver resolver)
      : resolver_(std::move(resolver)),
        pip_window_(),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), "video_player_pip",
            &flutter::StandardMethodCodec::GetInstance())) {
    pip_window_.set_on_close([this]() { Exit(false); });
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      const auto& method = call.method_name();
      if (method == "isPipSupported") {
        result->Success(EncodableValue(true));
        return;
      }
      if (method == "isInPipMode") {
        result->Success(EncodableValue(active_));
        return;
      }
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      if (method == "enterPipMode") {
        const int64_t player_id =
            ReadInt(call.arguments(), "playerId", -1);
        const int64_t width =
            args ? ReadInt(call.arguments(), "width", 360) : 360;
        const int64_t height =
            args ? ReadInt(call.arguments(), "height", 203) : 203;
        if (player_id < 0) {
          result->Error("invalid_arguments", "A valid playerId is required.");
          return;
        }
        Enter(player_id, width, height);
        result->Success(EncodableValue(active_));
        return;
      }
      if (method == "exitPipMode" || method == "reset") {
        const bool restored = method == "exitPipMode";
        const bool exited = Exit(restored);
        if (method == "reset") {
          result->Success();
        } else {
          result->Success(EncodableValue(exited));
        }
        return;
      }
      result->NotImplemented();
    });
  }

  ~VideoPlayerCustomPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    Exit(false, false);
  }

 private:
  bool Enter(int64_t player_id, int64_t width, int64_t height) {
    if (active_) {
      return true;
    }
    const auto player = resolver_ ? resolver_(player_id) : nullptr;
    if (!player) {
      return false;
    }
    pip_window_.set_player(player);
    active_player_id_ = player_id;
    if (!pip_window_.Create(width, height)) {
      active_player_id_ = -1;
      return false;
    }
    active_ = true;
    NotifyEntered(true);
    return true;
  }

  bool Exit(bool restored, bool notify = true) {
    if (!active_) {
      return false;
    }
    active_ = false;
    pip_window_.Close();
    active_player_id_ = -1;
    if (notify) {
      NotifyEntered(false);
      if (restored) {
        channel_->InvokeMethod(
            "onPipRestore",
            std::make_unique<EncodableValue>(EncodableMap{
                {EncodableValue("isInPipMode"), EncodableValue(false)}}));
      }
    }
    return true;
  }

  void NotifyEntered(bool entered) {
    channel_->InvokeMethod(
        "pipChanged",
        std::make_unique<EncodableValue>(EncodableMap{
            {EncodableValue("isInPipMode"), EncodableValue(entered)}}));
  }

  PlayerResolver resolver_;
  PipWindow pip_window_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  int64_t active_player_id_ = -1;
  bool active_ = false;
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

 public:
  std::shared_ptr<video_player_custom::WmfVideoPlayer> GetPlayer(
      int64_t player_id) {
    std::lock_guard<std::mutex> lock(players_mutex_);
    const auto it = players_.find(player_id);
    return it == players_.end() ? nullptr : it->second->player;
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
  // Desktop plugin first: the PiP plugin holds a resolver pointing at it, so
  // it must outlive the PiP plugin (plugins are destroyed in reverse
  // registration order).
  auto desktop = std::make_unique<DesktopVideoPlayerPlugin>(windows_registrar);
  auto* desktop_raw = desktop.get();
  windows_registrar->AddPlugin(std::move(desktop));
  windows_registrar->AddPlugin(
      std::make_unique<VideoPlayerCustomPlugin>(
          windows_registrar,
          [desktop_raw](int64_t player_id) {
            return desktop_raw ? desktop_raw->GetPlayer(player_id) : nullptr;
          }));
}