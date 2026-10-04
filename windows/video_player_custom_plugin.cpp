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
#include <cstdlib>
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

// A separate, always-on-top window. The Flutter view keeps its own size and
// texture; both views consume frames from the same native player.
class PipWindow {
 public:
  enum class Action { kClose, kRestore };

  ~PipWindow() { Close(); }

  void set_on_action(std::function<void(Action)> on_action) {
    on_action_ = std::move(on_action);
  }

  void set_player(std::shared_ptr<video_player_custom::WmfVideoPlayer> player) {
    player_ = std::move(player);
  }

  bool Create(int64_t width, int64_t height, HWND host) {
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
    if (!GetMonitorInfo(MonitorFromWindow(host, MONITOR_DEFAULTTOPRIMARY),
                        &monitor)) {
      return false;
    }
    const RECT& work = monitor.rcWork;
    const int w = static_cast<int>(std::clamp<int64_t>(
        width, 180, std::max<LONG>(180, work.right - work.left)));
    const int h = static_cast<int>(std::clamp<int64_t>(
        height, 120, std::max<LONG>(120, work.bottom - work.top)));
    HWND hwnd = CreateWindowEx(
        // Open without stealing focus below, but allow activation on a click:
        // background-only windows cannot capture an out-of-bounds seek drag.
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kClassName,
        L"Video Player (PiP)", WS_POPUP | WS_THICKFRAME, work.right - w - 16,
        work.bottom - h - 16, w, h, nullptr, nullptr, instance, this);
    if (!hwnd) {
      return false;
    }
    last_generation_ = -1;
    last_playing_ = !Player()->IsPlaying();
    last_position_ms_ = -1;
    controls_visible_ = false;
    mouse_over_video_ = false;
    tracking_mouse_ = false;
    hide_at_ms_ = 0;
    POINT cursor;
    if (GetCursorPos(&cursor) && WindowFromPoint(cursor) == hwnd) {
      ScreenToClient(hwnd, &cursor);
      UpdateHover(hwnd, cursor);
    }
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    if (!SetTimer(hwnd, kRenderTimerId, kRenderIntervalMs, nullptr)) {
      Close();
      return false;
    }
    return true;
  }

  void Close() {
    if (window_) DestroyWindow(window_);
    ReleaseBackBuffer();
    player_.reset();
    pressed_ = Button::kNone;
    hover_ = Button::kNone;
    seek_preview_ms_ = -1;
  }

 private:
  static constexpr UINT kRenderTimerId = 0x5049;
  static constexpr UINT kRenderIntervalMs = 16;
  static constexpr int kBandPx = 32;
  static constexpr int kButtonPx = 32;
  static constexpr int kResizeBorderPx = 6;
  static constexpr int kControlRadiusPx = 22;
  static constexpr int kControlSpacingPx = 56;
  static constexpr int kSeekMarginPx = 16;
  static constexpr ULONGLONG kControlsHideDelayMs = 2500;
  enum class Button {
    kNone, kClose, kRestore, kRewind, kPlayPause, kForward, kSeek, kVideo
  };
  static constexpr const wchar_t kClassName[] =
      L"VideoPlayerCustom_PipWindow";

  std::shared_ptr<video_player_custom::WmfVideoPlayer> Player() const {
    return player_.lock();
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    auto* self = reinterpret_cast<PipWindow*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<PipWindow*>(
          reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
      self->window_ = hwnd;
      SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (!self) {
      return DefWindowProc(hwnd, message, wparam, lparam);
    }
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }

  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
      case WM_NCCALCSIZE:
        // Keep WS_THICKFRAME's resizing behavior without a system caption.
        return 0;
      case WM_NCHITTEST:
        return OnHitTest(hwnd, lparam);
      case WM_NCLBUTTONDBLCLK:
        return 0;
      case WM_GETMINMAXINFO: {
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        info->ptMinTrackSize = POINT{180, 120};
        return 0;
      }
      case WM_LBUTTONDOWN: {
        const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        UpdateHover(hwnd, point);
        pressed_ = ButtonAt(hwnd, point);
        if (pressed_ != Button::kNone) SetCapture(hwnd);
        if (pressed_ == Button::kSeek) UpdateSeekPreview(hwnd, point.x);
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      }
      case WM_LBUTTONUP: {
        const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        const Button pressed = pressed_;
        if (pressed == Button::kSeek) {
          UpdateSeekPreview(hwnd, point.x);
          if (const auto player = Player(); player && seek_preview_ms_ >= 0) {
            player->SeekTo(seek_preview_ms_);
          }
        }
        pressed_ = Button::kNone;
        seek_preview_ms_ = -1;
        if (GetCapture() == hwnd) ReleaseCapture();
        UpdateHover(hwnd, point);
        InvalidateRect(hwnd, nullptr, FALSE);
        const Button released = ButtonAt(hwnd, point);
        if (pressed != released) return 0;
        if (pressed == Button::kClose || pressed == Button::kRestore) {
          const auto callback = on_action_;
          if (callback) callback(pressed == Button::kClose ? Action::kClose
                                                         : Action::kRestore);
        } else if (pressed == Button::kVideo || pressed == Button::kPlayPause) {
          TogglePlayPause();
        } else if (pressed == Button::kRewind || pressed == Button::kForward) {
          SeekRelative(pressed == Button::kRewind ? -10000 : 10000);
        }
        return 0;
      }
      case WM_CAPTURECHANGED:
        pressed_ = Button::kNone;
        seek_preview_ms_ = -1;
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      case WM_CANCELMODE:
        pressed_ = Button::kNone;
        seek_preview_ms_ = -1;
        if (GetCapture() == hwnd) ReleaseCapture();
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      case WM_MOUSEMOVE: {
        const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        UpdateHover(hwnd, point);
        if (pressed_ == Button::kSeek) UpdateSeekPreview(hwnd, point.x);
        return 0;
      }
      case WM_MOUSELEAVE:
        tracking_mouse_ = false;
        mouse_over_video_ = false;
        hover_ = Button::kNone;
        hide_at_ms_ = GetTickCount64() + kControlsHideDelayMs;
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      case WM_TIMER:
        if (wparam == kRenderTimerId) RefreshIfChanged();
        return 0;
      case WM_ERASEBKGND:
        return 1;
      case WM_SIZE:
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        Paint(ps.hdc);
        EndPaint(hwnd, &ps);
        return 0;
      }
      case WM_CLOSE:
        if (on_action_) on_action_(Action::kClose);
        else Close();
        return 0;
      case WM_DESTROY:
        KillTimer(hwnd, kRenderTimerId);
        pressed_ = Button::kNone;
        seek_preview_ms_ = -1;
        ReleaseBackBuffer();
        return 0;
      case WM_NCDESTROY:
        SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
        window_ = nullptr;
        break;
    }
    return DefWindowProc(hwnd, message, wparam, lparam);
  }

  LRESULT OnHitTest(HWND hwnd, LPARAM lparam) {
    POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(hwnd, &pt);
    RECT rc;
    GetClientRect(hwnd, &rc);
    const bool left = pt.x < kResizeBorderPx;
    const bool right = pt.x >= rc.right - kResizeBorderPx;
    const bool top = pt.y < kResizeBorderPx;
    const bool bottom = pt.y >= rc.bottom - kResizeBorderPx;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
    if (pt.y < kBandPx && pt.x < rc.right - kButtonPx * 2) {
      return HTCAPTION;
    }
    return HTCLIENT;
  }

  Button ButtonAt(HWND hwnd, POINT pt) const {
    RECT rc;
    GetClientRect(hwnd, &rc);
    if (!PtInRect(&rc, pt)) return Button::kNone;
    if (pt.y < kBandPx) {
      if (pt.x >= rc.right - kButtonPx) return Button::kClose;
      if (pt.x >= rc.right - kButtonPx * 2) return Button::kRestore;
      return Button::kNone;
    }
    if (controls_visible_) {
      const auto player = Player();
      const bool seekable = player && player->GetDurationMs() > 0;
      if (pt.y >= rc.bottom - 32 && pt.y < rc.bottom - 8 &&
          pt.x >= kSeekMarginPx - 8 &&
          pt.x <= rc.right - kSeekMarginPx + 8) {
        return seekable ? Button::kSeek : Button::kNone;
      }
      const int center_y = ControlCenterY(rc);
      const int radius = ControlRadius(rc);
      if (std::abs(pt.y - center_y) <= radius) {
        if (std::abs(pt.x - rc.right / 2) <= radius) {
          return Button::kPlayPause;
        }
        if (std::abs(pt.x - (rc.right / 2 - kControlSpacingPx)) <= radius) {
          return seekable ? Button::kRewind : Button::kNone;
        }
        if (std::abs(pt.x - (rc.right / 2 + kControlSpacingPx)) <= radius) {
          return seekable ? Button::kForward : Button::kNone;
        }
      }
    }
    return Button::kVideo;
  }

  static int ControlCenterY(const RECT& rc) {
    // At compact sizes reserve the seek panel before placing the buttons.
    // Their hit areas must never overlap the seek bar or title controls.
    const int available = rc.bottom - kBandPx - (rc.bottom < 180 ? 48 : 0);
    return kBandPx + available / 2;
  }

  static int ControlRadius(const RECT& rc) {
    return std::min(kControlRadiusPx,
        std::max(14, (static_cast<int>(rc.bottom) - kBandPx - 48) / 2 - 2));
  }

  void UpdateHover(HWND hwnd, POINT point) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    const bool inside = PtInRect(&rc, point) && point.y >= kBandPx;
    bool changed = false;
    if (inside) {
      changed = !controls_visible_;
      controls_visible_ = true;
      mouse_over_video_ = true;
      hide_at_ms_ = 0;
    } else if (mouse_over_video_) {
      mouse_over_video_ = false;
      hide_at_ms_ = GetTickCount64() + kControlsHideDelayMs;
    }
    if (!tracking_mouse_ && PtInRect(&rc, point)) {
      TRACKMOUSEEVENT track{sizeof(TRACKMOUSEEVENT), TME_LEAVE, hwnd, 0};
      tracking_mouse_ = TrackMouseEvent(&track) != FALSE;
    }
    const Button hover = ButtonAt(hwnd, point);
    changed = changed || hover != hover_;
    hover_ = hover;
    SetCursor(LoadCursor(nullptr,
        hover != Button::kNone && hover != Button::kVideo ? IDC_HAND : IDC_ARROW));
    if (changed) InvalidateRect(hwnd, nullptr, FALSE);
  }

  void UpdateSeekPreview(HWND hwnd, int x) {
    const auto player = Player();
    if (!player || player->GetDurationMs() <= 0) return;
    RECT rc;
    GetClientRect(hwnd, &rc);
    const int track_width = std::max(1, static_cast<int>(rc.right) - kSeekMarginPx * 2);
    const double fraction = static_cast<double>(
        std::clamp(x - kSeekMarginPx, 0, track_width)) / track_width;
    seek_preview_ms_ = static_cast<int64_t>(fraction * player->GetDurationMs());
    InvalidateRect(hwnd, nullptr, FALSE);
  }

  void SeekRelative(int64_t offset_ms) {
    const auto player = Player();
    if (!player || !player->CanEnterPip() || player->GetDurationMs() <= 0) return;
    player->SeekBy(offset_ms);
  }

  void TogglePlayPause() {
    const auto player = Player();
    if (!player || !player->CanEnterPip()) {
      return;
    }
    if (player->IsPlaying()) {
      player->Pause();
    } else {
      const int64_t duration = player->GetDurationMs();
      if (duration > 0 && player->GetPositionMs() >= duration) player->SeekTo(0);
      player->Play();
    }
  }

  void RefreshIfChanged() {
    const auto player = Player();
    if (!player || !player->CanEnterPip()) {
      if (on_action_) on_action_(Action::kClose);
      return;
    }
    const int64_t generation = player->frame_generation();
    const bool playing = player->IsPlaying();
    const int64_t position_ms = player->GetPositionMs();
    const bool hide = controls_visible_ && !mouse_over_video_ &&
        pressed_ == Button::kNone && hide_at_ms_ != 0 &&
        GetTickCount64() >= hide_at_ms_;
    if (hide) {
      controls_visible_ = false;
      hide_at_ms_ = 0;
      hover_ = Button::kNone;
    }
    if (!hide && generation == last_generation_ && playing == last_playing_ &&
        (!controls_visible_ || position_ms == last_position_ms_)) {
      return;
    }
    last_generation_ = generation;
    last_playing_ = playing;
    last_position_ms_ = position_ms;
    InvalidateRect(window_, nullptr, FALSE);
  }

  bool EnsureBackBuffer(HDC display_dc, int width, int height) {
    if (back_bitmap_ && back_width_ == width && back_height_ == height) {
      return true;
    }
    if (!back_dc_) back_dc_ = CreateCompatibleDC(display_dc);
    if (!back_dc_) return false;

    // Use the display DC to create a color bitmap. A newly created memory DC
    // initially contains a monochrome bitmap and would create the wrong format.
    const HBITMAP replacement =
        CreateCompatibleBitmap(display_dc, width, height);
    if (!replacement) return false;
    const HGDIOBJ previous = SelectObject(back_dc_, replacement);
    if (!previous || previous == HGDI_ERROR) {
      DeleteObject(replacement);
      return false;
    }
    if (back_bitmap_) DeleteObject(back_bitmap_);
    else back_original_bitmap_ = previous;
    back_bitmap_ = replacement;
    back_width_ = width;
    back_height_ = height;

    // BLACKONWHITE's default bitwise reduction distorts color video. HALFTONE
    // averages source pixels; its brush origin must be set after the mode.
    SetStretchBltMode(back_dc_, HALFTONE);
    SetBrushOrgEx(back_dc_, 0, 0, nullptr);
    return true;
  }

  void ReleaseBackBuffer() {
    if (back_dc_ && back_original_bitmap_) {
      SelectObject(back_dc_, back_original_bitmap_);
    }
    if (back_bitmap_) DeleteObject(back_bitmap_);
    if (back_dc_) DeleteDC(back_dc_);
    back_bitmap_ = nullptr;
    back_dc_ = nullptr;
    back_original_bitmap_ = nullptr;
    back_width_ = back_height_ = 0;
  }

  void Paint(HDC display_dc) {
    RECT rc;
    GetClientRect(window_, &rc);
    const int width = rc.right - rc.left;
    const int height = rc.bottom - rc.top;
    if (width <= 0 || height <= 0 ||
        !EnsureBackBuffer(display_dc, width, height)) return;
    PaintScene(back_dc_, rc);
    // Present one complete image. Clearing and drawing the video/controls on
    // the HWND separately exposes intermediate black frames to the viewer.
    BitBlt(display_dc, 0, 0, width, height, back_dc_, 0, 0, SRCCOPY);
  }

  void PaintScene(HDC dc, const RECT& rc) const {
    FillRect(dc, &rc, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    RECT video_rc = rc;
    video_rc.top += kBandPx;
    const auto player = Player();
    int64_t width = 0;
    int64_t height = 0;
    int64_t stride = 0;
    std::vector<uint8_t> data;
    if (player && video_rc.bottom > video_rc.top &&
        player->CopyCurrentFrame(&data, &width, &height, &stride) &&
        width > 0 && height > 0) {
      int draw_w;
      int draw_h;
      const double frame_aspect = static_cast<double>(width) / height;
      const double client_aspect =
          static_cast<double>(video_rc.right) / (video_rc.bottom - video_rc.top);
      if (frame_aspect > client_aspect) {
        draw_w = video_rc.right;
        draw_h = static_cast<int>(draw_w / frame_aspect);
      } else {
        draw_h = video_rc.bottom - video_rc.top;
        draw_w = static_cast<int>(draw_h * frame_aspect);
      }
      BITMAPINFO bi = {};
      bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
      bi.bmiHeader.biWidth = static_cast<LONG>(width);
      bi.bmiHeader.biHeight = -static_cast<LONG>(height);  // top-down rows
      bi.bmiHeader.biPlanes = 1;
      bi.bmiHeader.biBitCount = 32;
      bi.bmiHeader.biCompression = BI_RGB;
      StretchDIBits(dc, (video_rc.right - draw_w) / 2,
                    video_rc.top + (video_rc.bottom - video_rc.top - draw_h) / 2,
                    draw_w, draw_h,
                    0, 0, static_cast<int>(width), static_cast<int>(height),
                    data.data(), &bi, DIB_RGB_COLORS, SRCCOPY);
    }
    RECT title = rc;
    title.bottom = kBandPx;
    const HBRUSH band = CreateSolidBrush(RGB(32, 32, 32));
    FillRect(dc, &title, band);
    DeleteObject(band);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    const auto old_font = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
    title.left += 12;
    title.right -= kButtonPx * 2;
    DrawTextW(dc, L"Video (PiP)", -1, &title,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    SelectObject(dc, old_font);
    const HPEN pen = CreatePen(PS_SOLID, 2, RGB(255, 255, 255));
    const auto old_pen = SelectObject(dc, pen);
    const auto old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    const int close_x = rc.right - kButtonPx / 2;
    MoveToEx(dc, close_x - 5, 11, nullptr);
    LineTo(dc, close_x + 5, 21);
    MoveToEx(dc, close_x + 5, 11, nullptr);
    LineTo(dc, close_x - 5, 21);
    const int restore_x = close_x - kButtonPx;
    Rectangle(dc, restore_x - 6, 12, restore_x + 4, 22);
    MoveToEx(dc, restore_x - 3, 9, nullptr);
    LineTo(dc, restore_x + 7, 9);
    LineTo(dc, restore_x + 7, 19);
    SelectObject(dc, old_brush);
    SelectObject(dc, old_pen);
    DeleteObject(pen);
    if (controls_visible_ && player) PaintControls(dc, rc, *player);
  }

  static std::wstring TimeLabel(int64_t ms) {
    const int64_t seconds = std::max<int64_t>(0, ms) / 1000;
    const auto minutes = std::to_wstring((seconds / 60) % 60);
    const auto remainder = std::to_wstring(seconds % 60);
    const std::wstring suffix = (seconds % 60 < 10 ? L"0" : L"") + remainder;
    if (seconds < 3600) return std::to_wstring(seconds / 60) + L":" + suffix;
    return std::to_wstring(seconds / 3600) + L":" +
        ((seconds / 60) % 60 < 10 ? L"0" : L"") + minutes + L":" + suffix;
  }

  void PaintControls(HDC dc, const RECT& rc,
                     const video_player_custom::WmfVideoPlayer& player) const {
    const int64_t duration = player.GetDurationMs();
    const int64_t position = std::max<int64_t>(0,
        seek_preview_ms_ >= 0 ? seek_preview_ms_ : player.GetPositionMs());
    RECT bottom{0, std::max(kBandPx, static_cast<int>(rc.bottom) - 48),
                rc.right, rc.bottom};
    const HBRUSH background = CreateSolidBrush(RGB(24, 24, 24));
    FillRect(dc, &bottom, background);
    DeleteObject(background);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    const auto old_font = SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
    RECT time{16, rc.bottom - 46, rc.right - 16, rc.bottom - 28};
    const std::wstring label = TimeLabel(position) + L" / " +
        (duration > 0 ? TimeLabel(duration) : L"--:--");
    DrawTextW(dc, label.c_str(), -1, &time,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    const int track_width = std::max(1, static_cast<int>(rc.right) - 32);
    RECT track{16, rc.bottom - 22, rc.right - 16, rc.bottom - 18};
    const HBRUSH remaining = CreateSolidBrush(RGB(85, 85, 85));
    FillRect(dc, &track, remaining);
    DeleteObject(remaining);
    if (duration > 0) {
      RECT buffered = track;
      buffered.right = 16 + static_cast<LONG>(track_width *
          static_cast<double>(std::clamp<int64_t>(player.GetBufferedPositionMs(),
                                                 0, duration)) / duration);
      const HBRUSH buffer_brush = CreateSolidBrush(RGB(155, 155, 155));
      FillRect(dc, &buffered, buffer_brush);
      DeleteObject(buffer_brush);
      RECT played = track;
      played.right = 16 + static_cast<LONG>(track_width *
          static_cast<double>(std::min(position, duration)) / duration);
      const HBRUSH accent = CreateSolidBrush(RGB(255, 48, 48));
      FillRect(dc, &played, accent);
      const auto old_brush = SelectObject(dc, accent);
      const auto old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
      const int radius = hover_ == Button::kSeek || pressed_ == Button::kSeek ? 6 : 4;
      Ellipse(dc, played.right - radius, rc.bottom - 20 - radius,
              played.right + radius + 1, rc.bottom - 20 + radius + 1);
      SelectObject(dc, old_pen);
      SelectObject(dc, old_brush);
      DeleteObject(accent);
    }

    const int center_y = ControlCenterY(rc);
    const int radius = ControlRadius(rc);
    for (const Button button : {Button::kRewind, Button::kPlayPause,
                                Button::kForward}) {
      const int x = rc.right / 2 + (button == Button::kRewind ? -56 :
                                   button == Button::kForward ? 56 : 0);
      const bool enabled = button == Button::kPlayPause || duration > 0;
      const HBRUSH circle = CreateSolidBrush(
          enabled && (hover_ == button || pressed_ == button)
              ? RGB(65, 65, 65) : RGB(32, 32, 32));
      const auto old_brush = SelectObject(dc, circle);
      const auto old_pen = SelectObject(dc, GetStockObject(NULL_PEN));
      Ellipse(dc, x - radius, center_y - radius,
              x + radius + 1, center_y + radius + 1);
      const HBRUSH icon = CreateSolidBrush(enabled ? RGB(255, 255, 255) :
                                                    RGB(120, 120, 120));
      SelectObject(dc, icon);
      if (button == Button::kPlayPause) {
        if (player.IsPlaying()) {
          RECT left{x - 7, center_y - 9, x - 2, center_y + 9};
          RECT right{x + 2, center_y - 9, x + 7, center_y + 9};
          FillRect(dc, &left, icon);
          FillRect(dc, &right, icon);
        } else {
          POINT triangle[]{{x - 5, center_y - 10}, {x - 5, center_y + 10},
                           {x + 10, center_y}};
          Polygon(dc, triangle, 3);
        }
      } else {
        const int direction = button == Button::kRewind ? -1 : 1;
        for (const int offset : {-5, 5}) {
          const int tip = x + offset + direction * 4;
          POINT triangle[]{{tip, center_y - 6},
                           {tip - direction * 7, center_y - 12},
                           {tip - direction * 7, center_y}};
          Polygon(dc, triangle, 3);
        }
        SetTextColor(dc, enabled ? RGB(255, 255, 255) : RGB(120, 120, 120));
        RECT seconds{x - 18, center_y + 1, x + 18, center_y + 18};
        DrawTextW(dc, L"10", -1, &seconds, DT_CENTER | DT_SINGLELINE);
      }
      SelectObject(dc, old_brush);
      SelectObject(dc, old_pen);
      DeleteObject(icon);
      DeleteObject(circle);
    }
    SelectObject(dc, old_font);
  }

  std::weak_ptr<video_player_custom::WmfVideoPlayer> player_;
  std::function<void(Action)> on_action_;
  HWND window_ = nullptr;
  HDC back_dc_ = nullptr;
  HBITMAP back_bitmap_ = nullptr;
  HGDIOBJ back_original_bitmap_ = nullptr;
  int back_width_ = 0;
  int back_height_ = 0;
  bool registered_ = false;
  int64_t last_generation_ = -1;
  int64_t last_position_ms_ = -1;
  bool last_playing_ = false;
  bool controls_visible_ = false;
  bool mouse_over_video_ = false;
  bool tracking_mouse_ = false;
  ULONGLONG hide_at_ms_ = 0;
  int64_t seek_preview_ms_ = -1;
  Button hover_ = Button::kNone;
  Button pressed_ = Button::kNone;
};

// ---------------------------------------------------------------------------
// Picture-in-picture plugin channel (video_player_pip).
// ---------------------------------------------------------------------------

// Ties the native PiP window to Dart. The PiP window renders the player's
// frames itself, so the app's own window and UI keep running untouched.
using PlayerResolver = std::function<
    std::shared_ptr<video_player_custom::WmfVideoPlayer>(int64_t player_id)>;

class VideoPlayerCustomPlugin {
 public:
  explicit VideoPlayerCustomPlugin(flutter::PluginRegistrarWindows* registrar,
                                   PlayerResolver resolver)
      : resolver_(std::move(resolver)),
        host_window_(registrar->GetView()
                         ? GetAncestor(registrar->GetView()->GetNativeWindow(),
                                       GA_ROOT)
                         : nullptr),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), "video_player_pip",
            &flutter::StandardMethodCodec::GetInstance())) {
    pip_window_.set_on_action([this](PipWindow::Action action) {
      Exit(action == PipWindow::Action::kRestore, true);
    });
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
        result->Success(EncodableValue(Enter(player_id, width, height)));
        return;
      }
      if (method == "exitPipMode" || method == "reset") {
        const bool exited = Exit(false, method == "reset");
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

  ~VideoPlayerCustomPlugin() {
    channel_->SetMethodCallHandler(nullptr);
    Exit(false, true, false);
  }

  void OnPlayerDisposed(int64_t player_id) {
    if (active_player_id_ == player_id) Exit(false, true);
  }

 private:
  bool Enter(int64_t player_id, int64_t width, int64_t height) {
    if (width <= 0 || height <= 0) return false;
    if (active_) {
      return active_player_id_ == player_id;
    }
    const auto player = resolver_ ? resolver_(player_id) : nullptr;
    if (!player || !player->CanEnterPip()) {
      return false;
    }
    pip_window_.set_player(player);
    active_player_id_ = player_id;
    if (!pip_window_.Create(width, height, host_window_)) {
      pip_window_.set_player(nullptr);
      active_player_id_ = -1;
      return false;
    }
    active_ = true;
    NotifyEntered(true, player_id, player->GetPositionMs());
    return true;
  }

  bool Exit(bool restored, bool pause = false, bool notify = true) {
    if (!active_) {
      return false;
    }
    const int64_t player_id = active_player_id_;
    const auto player = resolver_ ? resolver_(player_id) : nullptr;
    const int64_t position = player ? player->GetPositionMs() : 0;
    if (pause && player) player->Pause();
    active_ = false;
    pip_window_.Close();
    active_player_id_ = -1;
    if (restored && IsWindow(host_window_)) {
      ShowWindow(host_window_, IsIconic(host_window_) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(host_window_);
    }
    if (notify) {
      if (restored) {
        channel_->InvokeMethod(
            "onPipRestore",
            std::make_unique<EncodableValue>(EncodableMap{
                {EncodableValue("isInPipMode"), EncodableValue(false)},
                {EncodableValue("playerId"), EncodableValue(player_id)},
                {EncodableValue("positionMs"), EncodableValue(position)}}));
      } else {
        NotifyEntered(false, player_id, position);
      }
    }
    return true;
  }

  void NotifyEntered(bool entered, int64_t player_id, int64_t position) {
    channel_->InvokeMethod(
        "pipModeChanged",
        std::make_unique<EncodableValue>(EncodableMap{
            {EncodableValue("isInPipMode"), EncodableValue(entered)},
            {EncodableValue("playerId"), EncodableValue(player_id)},
            {EncodableValue("positionMs"), EncodableValue(position)}}));
  }

  PlayerResolver resolver_;
  HWND host_window_ = nullptr;
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
    // PiP and playback share one plugin owner. Registrar plugin destruction
    // order is unspecified, so a separately registered raw resolver is unsafe.
    pip_ = std::make_unique<VideoPlayerCustomPlugin>(
        registrar, [this](int64_t id) { return GetPlayer(id); });
  }

  ~DesktopVideoPlayerPlugin() override {
    lifetime_.reset();
    channel_->SetMethodCallHandler(nullptr);
    pip_.reset();
    std::lock_guard<std::mutex> lock(players_mutex_);
    for (auto& [id, entry] : players_) {
      const auto player = entry->player;
      player->Dispose();
      if (player->texture_id() >= 0) {
        textures_->UnregisterTexture(player->texture_id(),
                                     [player]() { (void)player; });
      }
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

    std::map<std::string, std::string> http_headers;
    if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
      const auto headers = args->find(EncodableValue("httpHeaders"));
      if (headers != args->end()) {
        if (const auto* map = std::get_if<EncodableMap>(&headers->second)) {
          for (const auto& [name, value] : *map) {
            const auto* key = std::get_if<std::string>(&name);
            const auto* text = std::get_if<std::string>(&value);
            if (key && text) http_headers[*key] = *text;
          }
        }
      }
    }
    const auto player = entry->player;
    {
      std::lock_guard<std::mutex> lock(players_mutex_);
      players_[player_id] = std::move(entry);
    }
    const std::weak_ptr<int> lifetime = lifetime_;
    const auto response =
        std::shared_ptr<flutter::MethodResult<EncodableValue>>(std::move(result));
    // Opening a URL must not block Flutter's merged platform/UI thread. Event
    // channels were installed above; the initialization event is cached until
    // Dart receives this reply and subscribes to it.
    player->InitializeAsync(
        uri, std::move(http_headers),
        [this, lifetime, player_id, response](bool initialized,
                                             const std::string& error) {
          if (lifetime.expired()) return;
          const auto initialized_player = GetPlayer(player_id);
          if (!initialized || !initialized_player) {
            DestroyPlayer(player_id);
            response->Error("video_error", error);
            return;
          }
          response->Success(EncodableValue(EncodableMap{
              {EncodableValue("playerId"), EncodableValue(player_id)},
              {EncodableValue("textureId"),
               EncodableValue(initialized_player->texture_id())},
          }));
        });
  }

  void DestroyPlayer(int64_t id) {
    // Notify before removing the entry so PiP can obtain its final position,
    // pause the owner and release the HWND before the decoder is disposed.
    if (pip_) pip_->OnPlayerDisposed(id);
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
    if (player->texture_id() >= 0) {
      textures_->UnregisterTexture(player->texture_id(),
                                   [player]() { (void)player; });
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<flutter::TextureRegistrar> textures_;
  std::shared_ptr<video_player_custom::TaskPoster> poster_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::mutex players_mutex_;
  std::map<int64_t, std::unique_ptr<DesktopPlayerEntry>> players_;
  int64_t next_player_id_ = 1;
  std::unique_ptr<VideoPlayerCustomPlugin> pip_;
  std::shared_ptr<int> lifetime_ = std::make_shared<int>(0);
};

}  // namespace

void VideoPlayerCustomPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(
      std::make_unique<DesktopVideoPlayerPlugin>(windows_registrar));
}
