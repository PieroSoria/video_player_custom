// Windows desktop video backend built directly on Windows Media Foundation.
//
// The player decodes audio/video with an IMFSourceReader, renders video as
// 32-bit BGRA frames through a Flutter pixel-buffer texture and plays audio
// through WASAPI (shared mode). No third-party playback packages are used.
//
// All Media Foundation / WASAPI objects live on a single worker (pump) thread
// initialized as an MTA, so no COM apartment marshalling is required.

#include "wmf_video_player.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <Mfobjects.h>
#include <mferror.h>
#include <propidl.h>
#include <winhttp.h>
#include <wrl/implements.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <utility>

#include <wchar.h>

namespace video_player_custom {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                       static_cast<int>(wide.size()), nullptr, 0,
                                       nullptr, nullptr);
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring result(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      result.data(), size);
  return result;
}

// Each raster request owns its RGBA bytes until Flutter has uploaded them.
// The decoder's BGRA ring remains available independently to the GDI PiP view.
struct TextureFrameSnapshot {
  std::vector<uint8_t> rgba;
  FlutterDesktopPixelBuffer pixels = {};
};

// Media Foundation's URL reader does not expose arbitrary request headers.
// This seekable WinHTTP stream preserves them on every request, including
// range requests after seeks. MF still performs all demuxing and decoding.
class HeaderHttpStream final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          IStream> {
 public:
  ~HeaderHttpStream() {
    if (request_) WinHttpCloseHandle(request_);
    if (connection_) WinHttpCloseHandle(connection_);
    if (session_) WinHttpCloseHandle(session_);
  }

  HRESULT Open(const std::wstring& url,
               const std::map<std::string, std::string>& headers,
               std::shared_ptr<std::atomic<bool>> cancelled) {
    cancelled_ = std::move(cancelled);
    if (Cancelled()) return STG_E_REVERTED;
    URL_COMPONENTS parts = {};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = parts.dwUrlPathLength =
        parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts)) return LastError();
    if (parts.nScheme != INTERNET_SCHEME_HTTP &&
        parts.nScheme != INTERNET_SCHEME_HTTPS) return E_INVALIDARG;
    secure_ = parts.nScheme == INTERNET_SCHEME_HTTPS;
    path_.assign(parts.lpszUrlPath, parts.dwUrlPathLength);
    path_.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    if (path_.empty()) path_ = L"/";
    const size_t fragment = path_.find(L'#');
    if (fragment != std::wstring::npos) path_.resize(fragment);
    for (const auto& [name, header_value] : headers) {
      if (name.empty() || name.find_first_of("\r\n:") != std::string::npos ||
          header_value.find_first_of("\r\n") != std::string::npos ||
          name.find('\0') != std::string::npos ||
          header_value.find('\0') != std::string::npos) return E_INVALIDARG;
      // The decoder controls byte ranges and must receive uncompressed bytes.
      if (_stricmp(name.c_str(), "Range") == 0 ||
          _stricmp(name.c_str(), "Accept-Encoding") == 0) continue;
      headers_ += WideFromUtf8(name + ": " + header_value + "\r\n");
    }
    headers_ += L"Accept-Encoding: identity\r\n";
    session_ = WinHttpOpen(L"video_player_custom/1.0",
                          WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session_) return LastError();
    WinHttpSetTimeouts(session_, 5000, 5000, 5000, 5000);
    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    connection_ = WinHttpConnect(session_, host.c_str(), parts.nPort, 0);
    if (!connection_) return LastError();
    return OpenRequest(0);
  }

  const std::wstring& content_type() const { return content_type_; }

  STDMETHODIMP Read(void* buffer, ULONG count, ULONG* bytes_read) override {
    if (bytes_read) *bytes_read = 0;
    if (!buffer && count > 0) return STG_E_INVALIDPOINTER;
    std::lock_guard<std::mutex> lock(mutex_);
    if (Cancelled()) return STG_E_REVERTED;
    if (count == 0) return S_OK;
    if (position_ >= length_) return S_FALSE;
    if (!request_) {
      const HRESULT hr = OpenRequest(position_);
      if (FAILED(hr)) return hr;
    }
    ULONG total = 0;
    const ULONG wanted = static_cast<ULONG>(
        std::min<uint64_t>(count, length_ - position_));
    while (total < wanted) {
      if (Cancelled()) return STG_E_REVERTED;
      DWORD read = 0;
      if (!WinHttpReadData(request_, static_cast<BYTE*>(buffer) + total,
                           wanted - total, &read)) return LastError();
      if (read == 0) break;
      total += read;
      position_ += read;
    }
    if (bytes_read) *bytes_read = total;
    return total == count ? S_OK : S_FALSE;
  }

  STDMETHODIMP Seek(LARGE_INTEGER offset, DWORD origin,
                    ULARGE_INTEGER* new_position) override {
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t base = 0;
    if (origin == STREAM_SEEK_CUR) base = position_;
    else if (origin == STREAM_SEEK_END) base = length_;
    else if (origin != STREAM_SEEK_SET) return STG_E_INVALIDFUNCTION;
    const uint64_t magnitude = offset.QuadPart < 0
        ? static_cast<uint64_t>(-(offset.QuadPart + 1)) + 1
        : static_cast<uint64_t>(offset.QuadPart);
    if ((offset.QuadPart < 0 && magnitude > base) ||
        (offset.QuadPart >= 0 && magnitude >
            std::numeric_limits<uint64_t>::max() - base))
      return STG_E_INVALIDFUNCTION;
    const uint64_t target = offset.QuadPart < 0 ? base - magnitude
                                              : base + magnitude;
    if (target != position_) {
      if (request_) WinHttpCloseHandle(request_);
      request_ = nullptr;
      position_ = target;
    }
    if (new_position) new_position->QuadPart = position_;
    return S_OK;
  }

  STDMETHODIMP Stat(STATSTG* stat, DWORD flags) override {
    if (!stat) return STG_E_INVALIDPOINTER;
    std::lock_guard<std::mutex> lock(mutex_);
    *stat = {};
    stat->type = STGTY_STREAM;
    stat->cbSize.QuadPart = length_;
    stat->grfMode = STGM_READ;
    if ((flags & STATFLAG_NONAME) == 0) {
      stat->pwcsName = static_cast<LPOLESTR>(CoTaskMemAlloc(sizeof(wchar_t)));
      if (!stat->pwcsName) return E_OUTOFMEMORY;
      stat->pwcsName[0] = L'\0';
    }
    return S_OK;
  }

  STDMETHODIMP CopyTo(IStream* destination, ULARGE_INTEGER count,
                      ULARGE_INTEGER* read, ULARGE_INTEGER* written) override {
    if (!destination) return STG_E_INVALIDPOINTER;
    if (read) read->QuadPart = 0;
    if (written) written->QuadPart = 0;
    std::array<BYTE, 65536> buffer;
    uint64_t remaining = count.QuadPart;
    while (remaining > 0) {
      ULONG actual = 0, output = 0;
      const HRESULT hr = Read(buffer.data(), static_cast<ULONG>(
          std::min<uint64_t>(remaining, buffer.size())), &actual);
      if (FAILED(hr)) return hr;
      if (read) read->QuadPart += actual;
      const HRESULT write_hr = destination->Write(buffer.data(), actual, &output);
      if (written) written->QuadPart += output;
      if (FAILED(write_hr)) return write_hr;
      if (output != actual) return STG_E_MEDIUMFULL;
      remaining -= actual;
      if (hr == S_FALSE || actual == 0) return S_FALSE;
    }
    return S_OK;
  }

  STDMETHODIMP Write(const void*, ULONG, ULONG*) override {
    return STG_E_ACCESSDENIED;
  }
  STDMETHODIMP SetSize(ULARGE_INTEGER) override { return STG_E_ACCESSDENIED; }
  STDMETHODIMP Commit(DWORD) override { return S_OK; }
  STDMETHODIMP Revert() override { return STG_E_INVALIDFUNCTION; }
  STDMETHODIMP LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override {
    return STG_E_INVALIDFUNCTION;
  }
  STDMETHODIMP UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override {
    return STG_E_INVALIDFUNCTION;
  }
  STDMETHODIMP Clone(IStream**) override { return E_NOTIMPL; }

 private:
  static HRESULT LastError() { return HRESULT_FROM_WIN32(GetLastError()); }

  std::wstring Header(DWORD query) const {
    DWORD bytes = 0;
    WinHttpQueryHeaders(request_, query, WINHTTP_HEADER_NAME_BY_INDEX,
                        nullptr, &bytes, WINHTTP_NO_HEADER_INDEX);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) return {};
    std::wstring header_text(bytes / sizeof(wchar_t), L'\0');
    if (!WinHttpQueryHeaders(request_, query, WINHTTP_HEADER_NAME_BY_INDEX,
                             header_text.data(), &bytes, WINHTTP_NO_HEADER_INDEX))
      return {};
    header_text.resize(bytes / sizeof(wchar_t));
    return header_text;
  }

  HRESULT OpenRequest(uint64_t position) {
    if (Cancelled()) return STG_E_REVERTED;
    request_ = WinHttpOpenRequest(connection_, L"GET", path_.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
        secure_ ? WINHTTP_FLAG_SECURE : 0);
    if (!request_) return LastError();
    std::wstring headers = headers_;
    if (position > 0) headers += L"Range: bytes=" + std::to_wstring(position) +
                                L"-\r\n";
    if (!WinHttpSendRequest(request_, headers.c_str(),
          static_cast<DWORD>(headers.size()), WINHTTP_NO_REQUEST_DATA, 0, 0, 0))
      return LastError();
    if (Cancelled()) return STG_E_REVERTED;
    if (!WinHttpReceiveResponse(request_, nullptr)) return LastError();
    if (Cancelled()) return STG_E_REVERTED;
    DWORD status = 0, status_size = sizeof(status);
    if (!WinHttpQueryHeaders(request_, WINHTTP_QUERY_STATUS_CODE |
          WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status,
          &status_size, WINHTTP_NO_HEADER_INDEX)) return LastError();
    if (status != 200 && status != 206)
      return HRESULT_FROM_WIN32(ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
    if (status == 206) {
      const std::wstring range = Header(WINHTTP_QUERY_CONTENT_RANGE);
      unsigned long long first = 0, last = 0, total = 0;
      if (swscanf_s(range.c_str(), L"bytes %llu-%llu/%llu", &first, &last,
                     &total) != 3 || first != position || total == 0 ||
          last < first || last != total - 1 ||
          (length_ != 0 && length_ != total))
        return HRESULT_FROM_WIN32(ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
      length_ = total;
    } else {
      const std::wstring length = Header(WINHTTP_QUERY_CONTENT_LENGTH);
      if (length.empty()) return MF_E_UNSUPPORTED_BYTESTREAM_TYPE;
      wchar_t* end = nullptr;
      const uint64_t response_length = wcstoull(length.c_str(), &end, 10);
      if (!end || *end != L'\0' || response_length == 0)
        return MF_E_UNSUPPORTED_BYTESTREAM_TYPE;
      if (length_ != 0 && length_ != response_length) return STG_E_READFAULT;
      length_ = response_length;
    }
    if (position == 0) {
      content_type_ = Header(WINHTTP_QUERY_CONTENT_TYPE);
      const size_t separator = content_type_.find(L';');
      if (separator != std::wstring::npos) content_type_.resize(separator);
    }
    if (position > 0 && status == 200) {
      // Servers without range support remain playable: skip bytes until the
      // requested absolute position while preserving the supplied headers.
      std::array<BYTE, 65536> discard;
      uint64_t remaining = position;
      while (remaining > 0) {
        if (Cancelled()) return STG_E_REVERTED;
        DWORD read = 0;
        if (!WinHttpReadData(request_, discard.data(), static_cast<DWORD>(
                std::min<uint64_t>(remaining, discard.size())), &read))
          return LastError();
        if (read == 0) return STG_E_READFAULT;
        remaining -= read;
      }
    }
    return S_OK;
  }

  HINTERNET session_ = nullptr;
  HINTERNET connection_ = nullptr;
  HINTERNET request_ = nullptr;
  std::wstring path_, headers_, content_type_;
  bool secure_ = false;
  uint64_t length_ = 0;
  uint64_t position_ = 0;
  std::mutex mutex_;
  std::shared_ptr<std::atomic<bool>> cancelled_;
  bool Cancelled() const { return cancelled_ && cancelled_->load(); }
};

std::string HResultToString(HRESULT hr) {
  wchar_t* message = nullptr;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, hr, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                 reinterpret_cast<wchar_t*>(&message), 0, nullptr);
  std::string result;
  if (message) {
    result = Utf8FromWide(message);
    LocalFree(message);
  } else {
    std::ostringstream oss;
    oss << "HRESULT 0x" << std::hex << static_cast<unsigned long>(hr);
    result = oss.str();
  }
  return result;
}

std::string ReadString(const EncodableMap* args, const char* key) {
  if (!args) return std::string();
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return std::string();
  if (const auto* value = std::get_if<std::string>(&it->second)) return *value;
  return std::string();
}

int64_t ReadInt(const EncodableMap* args, const char* key, int64_t fallback) {
  if (!args) return fallback;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  return fallback;
}

double ReadDouble(const EncodableMap* args, const char* key, double fallback) {
  if (!args) return fallback;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second))
    return static_cast<double>(*value);
  if (const auto* value = std::get_if<int64_t>(&it->second))
    return static_cast<double>(*value);
  return fallback;
}

bool ReadBool(const EncodableMap* args, const char* key, bool fallback) {
  if (!args) return fallback;
  const auto it = args->find(EncodableValue(key));
  if (it == args->end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

}  // namespace

// ---------------------------------------------------------------------------
// AudioSink
// ---------------------------------------------------------------------------

AudioSink::~AudioSink() { Close(); }

void AudioSink::Close() {
  Stop();
  device_.Reset();
  client_.Reset();
  render_.Reset();
  volume_.Reset();
}

bool AudioSink::Initialize(uint32_t sample_rate, uint32_t channels) {
  rate_ = sample_rate ? sample_rate : 48000;
  channels_ = channels ? channels : 2;

  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
    return false;
  }
  if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                 &device_))) {
    return false;
  }
  if (FAILED(device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                               reinterpret_cast<void**>(client_.GetAddressOf())))) {
    return false;
  }

  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(channels_);
  format.nSamplesPerSec = rate_;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(channels_ * 2);
  format.nAvgBytesPerSec = rate_ * format.nBlockAlign;
  format.cbSize = 0;

  constexpr REFERENCE_TIME kBufferDuration = 5000000;  // 500 ms.
  if (FAILED(client_->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, kBufferDuration,
                                 0, &format, nullptr))) {
    return false;
  }
  if (FAILED(client_->GetBufferSize(&buffer_frames_))) {
    return false;
  }
  if (FAILED(client_->GetService(IID_PPV_ARGS(&render_)))) {
    return false;
  }
  // Optional; the master volume is only set when available.
  client_->GetService(IID_PPV_ARGS(&volume_));
  return true;
}

void AudioSink::ResetClock() { frames_written_ = 0; }

void AudioSink::Start() {
  if (!client_ || started_) return;
  // Drop any stale frames left over from a previous pause.
  client_->Reset();
  frames_written_ = 0;
  if (SUCCEEDED(client_->Start())) started_ = true;
}

void AudioSink::Stop() {
  if (!client_ || !started_) return;
  client_->Stop();
  started_ = false;
}

bool AudioSink::Write(const void* buffer, size_t bytes) {
  if (!client_ || bytes == 0) return true;
  const uint8_t* src = static_cast<const uint8_t*>(buffer);
  const size_t frame_bytes = static_cast<size_t>(channels_) * 2;
  const size_t total_frames = bytes / frame_bytes;
  size_t written = 0;

  while (written < total_frames) {
    UINT32 padding = 0;
    if (FAILED(client_->GetCurrentPadding(&padding))) return false;
    const UINT32 available = padding > buffer_frames_ ? 0
                                                      : buffer_frames_ - padding;
    if (available == 0) {
      Sleep(5);
      continue;
    }
    const UINT32 chunk =
        static_cast<UINT32>(std::min<size_t>(total_frames - written,
                                             static_cast<size_t>(available)));
    BYTE* dst = nullptr;
    if (FAILED(render_->GetBuffer(chunk, &dst))) return false;
    memcpy(dst, src + written * frame_bytes, chunk * frame_bytes);
    if (FAILED(render_->ReleaseBuffer(chunk, 0))) return false;
    written += chunk;
    frames_written_ += chunk;
  }
  return true;
}

int64_t AudioSink::GetPositionMs() const {
  if (!started_ || !client_) return 0;
  UINT32 padding = 0;
  if (FAILED(client_->GetCurrentPadding(&padding))) return 0;
  const uint64_t played =
      frames_written_ > padding ? frames_written_ - padding : 0;
  return static_cast<int64_t>(played * 1000 / rate_);
}

void AudioSink::SetVolume(float volume) {
  volume_level_ = std::clamp(volume, 0.0f, 1.0f);
  if (volume_) {
    volume_->SetMasterVolume(volume_level_, nullptr);
  }
}

// ---------------------------------------------------------------------------
// WmfVideoPlayer
// ---------------------------------------------------------------------------

WmfVideoPlayer::WmfVideoPlayer(
    std::shared_ptr<flutter::TextureRegistrar> textures,
    std::shared_ptr<TaskPoster> poster,
    EventCallback on_event)
    : textures_(std::move(textures)),
      poster_(std::move(poster)),
      on_event_(std::move(on_event)) {}

WmfVideoPlayer::~WmfVideoPlayer() { Dispose(); }

void WmfVideoPlayer::InitializeAsync(
    const std::string& url, std::map<std::string, std::string> http_headers,
    std::function<void(bool, const std::string&)> on_initialized) {
  url_ = url;
  http_headers_ = std::move(http_headers);
  on_initialized_ = std::move(on_initialized);
  pump_thread_ = std::thread([this]() { PumpLoop(); });
}

bool WmfVideoPlayer::Initialize(
    const std::string& url, std::string* error,
    std::map<std::string, std::string> http_headers) {
  url_ = url;
  http_headers_ = std::move(http_headers);
  ready_ = false;
  setup_failed_ = false;
  pump_thread_ = std::thread([this]() { PumpLoop(); });

  std::unique_lock<std::mutex> lock(ready_mutex_);
  const bool done = ready_cv_.wait_for(lock, std::chrono::seconds(20), [this]() {
    return ready_ || setup_failed_;
  });
  if (!done) {
    setup_failed_ = true;
    setup_error_ = "Timed out opening media source.";
  }
  if (setup_failed_) {
    if (error) *error = setup_error_;
    return false;
  }
  return true;
}

void WmfVideoPlayer::Dispose() {
  if (dispose_started_.exchange(true)) return;
  // Cancel pending platform notifications immediately, before waiting for
  // the decoder to stop. Their captures may outlive the plugin registrar.
  disposed_ = true;
  http_cancelled_->store(true);
  ready_ = false;
  playing_ = false;
  PostCommand(Command{CommandType::kDispose});
  if (pump_thread_.joinable()) pump_thread_.join();
}

void WmfVideoPlayer::Play() { PostCommand(Command{CommandType::kPlay}); }

void WmfVideoPlayer::Pause() { PostCommand(Command{CommandType::kPause}); }

void WmfVideoPlayer::SeekTo(int64_t position_ms) {
  PostCommand(Command{CommandType::kSeek, position_ms});
}

void WmfVideoPlayer::SeekBy(int64_t offset_ms) {
  PostCommand(Command{CommandType::kSeekBy, offset_ms});
}

void WmfVideoPlayer::SetLooping(bool looping) { looping_ = looping; }

void WmfVideoPlayer::SetVolume(float volume) {
  volume_ = std::clamp(volume, 0.0f, 1.0f);
  PostCommand(Command{CommandType::kSetVolume, 0, volume_});
}

void WmfVideoPlayer::SetPlaybackSpeed(float speed) {
  speed_ = speed > 0.0f ? speed : 1.0f;
}

int64_t WmfVideoPlayer::GetPositionMs() const { return position_ms_.load(); }

int64_t WmfVideoPlayer::GetBufferedPositionMs() const {
  const int64_t position = position_ms_.load();
  // Local files are fully buffered; streams report the position plus a small
  // playback-ahead window.
  const int64_t buffered = buffered_ms_.load();
  if (duration_ms_ > 0) return duration_ms_;
  return std::max(buffered, position);
}

void WmfVideoPlayer::PostCommand(Command command) {
  {
    std::lock_guard<std::mutex> lock(command_mutex_);
    commands_.push_back(command);
  }
  command_cv_.notify_all();
}

WmfVideoPlayer::Command WmfVideoPlayer::PopCommand() {
  std::unique_lock<std::mutex> lock(command_mutex_);
  // While playing, the pump keeps decoding even when the command queue is
  // empty; the condition variable only parks the thread when idle.
  command_cv_.wait(lock, [this]() {
    return disposed_ || playing_ || !commands_.empty();
  });
  if (!commands_.empty()) {
    Command command = commands_.front();
    commands_.pop_front();
    return command;
  }
  return Command{CommandType::kNone};
}

void WmfVideoPlayer::Emit(PlayerEvent event) {
  if (!poster_) {
    if (on_event_) on_event_(event);
    return;
  }
  // Channel sends must happen on the platform thread; the pump thread runs on
  // its own thread. Holding |self| keeps the player alive until the task runs.
  auto self = shared_from_this();
  poster_->Post(
      [self, event]() {
        if (!self->disposed_ && self->on_event_) self->on_event_(event);
      });
}

void WmfVideoPlayer::PumpLoop() {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  // RPC_E_CHANGED_MODE means the thread was already initialized in another
  // mode, which is fine for WMF.
  const bool com_ok =
      SUCCEEDED(com_result) || com_result == RPC_E_CHANGED_MODE;

  const HRESULT startup = MFStartup(MF_VERSION, MFSTARTUP_FULL);

  if (com_ok && SUCCEEDED(startup)) {
    std::string error;
    if (!SetupMedia(&error)) {
      std::lock_guard<std::mutex> lock(ready_mutex_);
      setup_failed_ = true;
      setup_error_ = error;
      ready_cv_.notify_all();
    } else {
      {
        std::lock_guard<std::mutex> lock(ready_mutex_);
        ready_ = true;
        ready_cv_.notify_all();
      }
      Emit(PlayerEvent{PlayerEvent::Type::kInitialized, duration_ms_,
                       video_width_, video_height_, false, ""});
    }
  } else {
    std::lock_guard<std::mutex> lock(ready_mutex_);
    setup_failed_ = true;
    setup_error_ =
        com_ok
            ? "Media Foundation startup failed: " + HResultToString(startup)
            : "COM initialization failed: " + HResultToString(com_result);
    ready_cv_.notify_all();
  }

  if (on_initialized_) {
    auto self = shared_from_this();
    auto callback = std::move(on_initialized_);
    const std::string error = setup_error_;
    poster_->Post([self, callback = std::move(callback), error]() {
      if (!self->disposed_) callback(self->ready_.load(), error);
    });
  }

  while (!disposed_) {
    Command command = PopCommand();
    if (command.type == CommandType::kDispose) break;

    switch (command.type) {
      case CommandType::kPlay:
        if (!playing_) {
          audio_.Start();
          playing_ = true;
          first_video_frame_ = true;
          Emit(PlayerEvent{PlayerEvent::Type::kIsPlayingStateUpdate, 0, 0, 0,
                           true, ""});
        }
        break;
      case CommandType::kPause:
        if (playing_) {
          playing_ = false;
          audio_.Stop();
          Emit(PlayerEvent{PlayerEvent::Type::kIsPlayingStateUpdate, 0, 0, 0,
                           false, ""});
        }
        break;
      case CommandType::kSeek:
      case CommandType::kSeekBy: {
        audio_.Stop();
        int64_t target = command.position_ms;
        if (command.type == CommandType::kSeekBy) {
          const int64_t current = std::max<int64_t>(0, GetPositionMs());
          const int64_t offset = command.position_ms;
          // Saturate before adding; DoSeek applies the media duration limit.
          if (offset >= 0) {
            const int64_t maximum = std::numeric_limits<int64_t>::max();
            target = current > maximum - offset ? maximum : current + offset;
          } else {
            target = offset < -current ? 0 : current + offset;
          }
        }
        DoSeek(target);
        if (playing_) {
          audio_.Start();
          first_video_frame_ = true;
        }
        break;
      }
      case CommandType::kSetVolume:
        audio_.SetVolume(command.volume);
        break;
      case CommandType::kNone:
        break;
      default:
        break;
    }

    if (disposed_ || !playing_) continue;
    ReadPlayStep();
  }

  audio_.Close();
  reader_.Reset();
  if (SUCCEEDED(startup)) MFShutdown();
  if (com_ok) CoUninitialize();
}

bool WmfVideoPlayer::SetupMedia(std::string* error) {
  // --- Source reader -------------------------------------------------------
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 2);
  if (FAILED(hr)) {
    *error = "MFCreateAttributes failed: " + HResultToString(hr);
    return false;
  }
  attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
  // Let the source reader inject the video processor so RGB32 output is
  // available for sources whose decoders do not emit it natively.
  attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING,
                        TRUE);

  if (!http_headers_.empty() &&
      (_strnicmp(url_.c_str(), "http://", 7) == 0 ||
       _strnicmp(url_.c_str(), "https://", 8) == 0)) {
    auto http_stream = Microsoft::WRL::Make<HeaderHttpStream>();
    hr = http_stream ? http_stream->Open(WideFromUtf8(url_), http_headers_,
                                          http_cancelled_)
                     : E_OUTOFMEMORY;
    ComPtr<IMFByteStream> stream;
    if (SUCCEEDED(hr)) hr = MFCreateMFByteStreamOnStream(http_stream.Get(), &stream);
    if (SUCCEEDED(hr)) {
      ComPtr<IMFAttributes> stream_attributes;
      if (SUCCEEDED(stream.As(&stream_attributes))) {
        stream_attributes->SetString(MF_BYTESTREAM_ORIGIN_NAME,
                                      WideFromUtf8(url_).c_str());
        if (!http_stream->content_type().empty())
          stream_attributes->SetString(MF_BYTESTREAM_CONTENT_TYPE,
                                        http_stream->content_type().c_str());
      }
      hr = MFCreateSourceReaderFromByteStream(stream.Get(), attributes.Get(),
                                               &reader_);
    }
  } else {
    hr = MFCreateSourceReaderFromURL(WideFromUtf8(url_).c_str(),
                                     attributes.Get(), &reader_);
  }
  if (FAILED(hr)) {
    *error = "Unable to open the media source: " + HResultToString(hr);
    return false;
  }

  // Enumerate the media streams through the source's presentation descriptor
  // and select the first video and audio stream.
  ComPtr<IMFMediaSource> media_source;
  if (FAILED(reader_->GetServiceForStream(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), GUID_NULL,
          IID_PPV_ARGS(&media_source)))) {
    *error = "Unable to access the media source for stream enumeration.";
    return false;
  }
  ComPtr<IMFPresentationDescriptor> presentation_descriptor;
  hr = media_source->CreatePresentationDescriptor(
      &presentation_descriptor);
  if (FAILED(hr)) {
    *error = "Unable to read the media presentation descriptor: " +
             HResultToString(hr);
    return false;
  }
  DWORD stream_count = 0;
  presentation_descriptor->GetStreamDescriptorCount(&stream_count);
  for (DWORD i = 0; i < stream_count; ++i) {
    BOOL selected = FALSE;
    ComPtr<IMFStreamDescriptor> descriptor;
    if (FAILED(presentation_descriptor->GetStreamDescriptorByIndex(
            i, &selected, &descriptor))) {
      continue;
    }
    ComPtr<IMFMediaTypeHandler> handler;
    descriptor->GetMediaTypeHandler(&handler);
    GUID major_type = GUID_NULL;
    handler->GetMajorType(&major_type);
    if (major_type == MFMediaType_Video && video_stream_ ==
                                               static_cast<DWORD>(-1)) {
      video_stream_ = i;
      reader_->SetStreamSelection(i, TRUE);
    } else if (major_type == MFMediaType_Audio &&
               audio_stream_ == static_cast<DWORD>(-1)) {
      audio_stream_ = i;
      reader_->SetStreamSelection(i, TRUE);
    } else {
      reader_->SetStreamSelection(i, FALSE);
    }
  }
  if (video_stream_ == static_cast<DWORD>(-1) &&
      audio_stream_ == static_cast<DWORD>(-1)) {
    *error = "The media source has neither a video nor an audio stream.";
    return false;
  }

  // --- Duration -------------------------------------------------------------
  // The presentation attribute on the media source holds the duration in
  // 100-nanosecond units.
  PROPVARIANT duration_value;
  PropVariantInit(&duration_value);
  if (SUCCEEDED(reader_->GetPresentationAttribute(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
          &duration_value)) &&
      duration_value.vt == VT_UI8 && duration_value.uhVal.QuadPart > 0) {
    duration_ms_ =
        static_cast<int64_t>(duration_value.uhVal.QuadPart / 10000);
    buffered_ms_ = duration_ms_;
  }
  PropVariantClear(&duration_value);

  // --- Video stream ---------------------------------------------------------
  video_eof_ = true;
  if (video_stream_ != static_cast<DWORD>(-1)) {
    ComPtr<IMFMediaType> output_type;
    if (!ConfigureVideoOutput(&output_type, error)) {
      return false;
    }

    UINT32 width = 0, height = 0;
    MFGetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE, &width, &height);
    if (width == 0 || height == 0) {
      // Some sources report the frame size only on their native type.
      ComPtr<IMFMediaType> native_type;
      if (SUCCEEDED(
              reader_->GetCurrentMediaType(video_stream_, &native_type))) {
        MFGetAttributeSize(native_type.Get(), MF_MT_FRAME_SIZE, &width,
                           &height);
      }
    }
    video_width_ = width;
    video_height_ = height;
    video_eof_ = false;

    UINT32 stride_raw = 0;
    if (FAILED(output_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_raw))) {
      stride_raw = 0;
    }
    int32_t stride = static_cast<int32_t>(stride_raw);
    if (stride == 0) stride = static_cast<int32_t>(width * 4);
    bottom_up_ = stride < 0;
    frame_byte_stride_ =
        static_cast<int64_t>(std::max<int32_t>(stride < 0 ? -stride : stride,
                                               static_cast<int32_t>(width * 4)));

    const int64_t buffer_bytes = video_width_ * 4 * video_height_;
    for (FrameSlot& slot : frame_slots_) {
      slot.data.resize(static_cast<size_t>(buffer_bytes));
      slot.width = video_width_;
      slot.height = video_height_;
    }
  }

  // --- Audio stream ---------------------------------------------------------
  audio_eof_ = true;
  audio_present_ = false;
  if (audio_stream_ != static_cast<DWORD>(-1)) {
    ComPtr<IMFMediaType> native_audio;
    if (SUCCEEDED(reader_->GetCurrentMediaType(audio_stream_, &native_audio))) {
      UINT32 rate = 48000, channels = 2;
      native_audio->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
      native_audio->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);

      ComPtr<IMFMediaType> pcm_type;
      MFCreateMediaType(&pcm_type);
      pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
      pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
      pcm_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
      pcm_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * channels * 2);

      if (SUCCEEDED(reader_->SetCurrentMediaType(audio_stream_, nullptr,
                                                 pcm_type.Get()))) {
        audio_rate_ = rate;
        audio_channels_ = channels;
        if (audio_.Initialize(rate, channels)) {
          audio_present_ = true;
          audio_eof_ = false;
          audio_.SetVolume(volume_);
        }
      }
    }
  }

  // --- Texture --------------------------------------------------------------
  texture_ = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture(
          [this](size_t /*width*/,
                 size_t /*height*/) -> const FlutterDesktopPixelBuffer* {
            auto snapshot = std::make_unique<TextureFrameSnapshot>();
            {
              std::lock_guard<std::mutex> lock(frame_mutex_);
              if (frame_generation_.load() == 0) return nullptr;
              const size_t slot =
                  (frame_slot_index_ - 1 + kFrameSlots) % kFrameSlots;
              const FrameSlot& frame = frame_slots_[slot];
              if (frame.data.empty()) return nullptr;
              snapshot->rgba = frame.data;
              snapshot->pixels.width = static_cast<size_t>(frame.width);
              snapshot->pixels.height = static_cast<size_t>(frame.height);
            }
            // Flutter's PixelBufferTexture uploads GL_RGBA; WMF/GDI use BGRA.
            for (size_t offset = 0; offset < snapshot->rgba.size(); offset += 4)
              std::swap(snapshot->rgba[offset], snapshot->rgba[offset + 2]);
            snapshot->pixels.buffer = snapshot->rgba.data();
            snapshot->pixels.release_context = snapshot.get();
            snapshot->pixels.release_callback = [](void* context) {
              delete static_cast<TextureFrameSnapshot*>(context);
            };
            return &snapshot.release()->pixels;
          }));
  texture_id_ = textures_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    *error = "Failed to register the video texture.";
    return false;
  }
  return true;
}

bool WmfVideoPlayer::ConfigureVideoOutput(ComPtr<IMFMediaType>* out_type,
                                          std::string* error) {
// 1) Prefer a source-provided RGB32/ARGB32 output type. These come straight
//    from the (possibly video-processor-enabled) source, so frame size,
//    stride and interlace fields are always consistent with what the decoder
//    can produce.
for (DWORD i = 0;; ++i) {
    ComPtr<IMFMediaType> available;
    HRESULT hr = reader_->GetNativeMediaType(video_stream_, i, &available);
    if (FAILED(hr)) break;
    GUID subtype = GUID_NULL;
    available->GetGUID(MF_MT_SUBTYPE, &subtype);
    if (subtype != MFVideoFormat_RGB32 && subtype != MFVideoFormat_ARGB32) {
      continue;
    }
    if (SUCCEEDED(reader_->SetCurrentMediaType(video_stream_, nullptr,
                                               available.Get()))) {
      *out_type = available;
      return true;
    }
  }

  // 2) Fall back to a hand-built RGB32 type. Only carry the frame size when the
  //    source reports one; forcing a size the decoder cannot match is a common
  //    cause of MF_E_INVALIDMEDIATYPE.
  ComPtr<IMFMediaType> native_type;
  HRESULT hr = reader_->GetCurrentMediaType(video_stream_, &native_type);
  if (FAILED(hr)) {
    *error = "Failed to read the video media type: " + HResultToString(hr);
    return false;
  }
  UINT32 width = 0, height = 0;
  MFGetAttributeSize(native_type.Get(), MF_MT_FRAME_SIZE, &width, &height);

  ComPtr<IMFMediaType> rgb_type;
  MFCreateMediaType(&rgb_type);
  rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  rgb_type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  if (width != 0 && height != 0) {
    MFSetAttributeSize(rgb_type.Get(), MF_MT_FRAME_SIZE, width, height);
  }
  hr = reader_->SetCurrentMediaType(video_stream_, nullptr, rgb_type.Get());
  if (SUCCEEDED(hr)) {
    *out_type = rgb_type;
    return true;
  }

  *error = "Failed to configure RGB32 output: " + HResultToString(hr);
  return false;
}

void WmfVideoPlayer::ReadPlayStep() {
  const bool has_video = video_stream_ != static_cast<DWORD>(-1);
  const bool has_audio = audio_stream_ != static_cast<DWORD>(-1);

  if (has_video && !video_eof_) {
    ComPtr<IMFSample> video_sample;
    bool video_eof = false;
    bool type_changed = false;
    const int64_t start_ms = NowMs();
    ReadVideoSample(&video_sample, &video_eof, &type_changed);
    const int64_t elapsed_ms = NowMs() - start_ms;

    if (type_changed) RefreshVideoOutput();
    if (video_eof) {
      video_eof_ = true;
    }

    // Network buffering detection using the elapsed read time.
    if (elapsed_ms > 250 && !was_buffering_) {
      was_buffering_ = true;
      Emit(PlayerEvent{PlayerEvent::Type::kBufferingStart});
    } else if (elapsed_ms <= 250 && was_buffering_) {
      was_buffering_ = false;
      Emit(PlayerEvent{PlayerEvent::Type::kBufferingEnd});
    }

    if (disposed_ || !playing_) return;

    if (video_sample && !video_eof_) {
      LONGLONG pts = 0;
      video_sample->GetSampleTime(&pts);
      const int64_t pts_ms = static_cast<int64_t>(pts / 10000);
      // WMF may seek to an earlier keyframe. Decode that preroll without
      // publishing old frames or moving the reported position backwards.
      if (pts_ms < seek_target_ms_) return;
      position_ms_ = pts_ms;

      if (has_video_stream_audio_deadline(has_audio)) {
        WriteAudioForDeadline(pts_ms);
        if (disposed_ || !playing_) return;
        PresentFrame(video_sample);
      } else {
        if (has_audio && !audio_eof_) {
          WriteOneAudioSample();
        }
        PresentPaced(video_sample, pts);
      }
    }
  }

  // Drain any audio tail after the last video frame as well as audio-only
  // media. Otherwise a seek to the duration can leave video EOF waiting for
  // audio EOF forever, without delivering the completion event.
  if ((!has_video || video_eof_) && has_audio && !audio_eof_) {
    WriteOneAudioSample();
  }

  const bool video_done = !has_video || video_eof_;
  const bool audio_done = !has_audio || audio_eof_;
  if (video_done && audio_done) {
    HandleEndOfStream();
  }
}

bool WmfVideoPlayer::has_video_stream_audio_deadline(bool has_audio) const {
  // With audio and a 1x playback rate the audio clock drives presentation.
  return has_audio && speed_ == 1.0f;
}

bool WmfVideoPlayer::WriteAudioForDeadline(int64_t deadline_ms) {
  if (!audio_present_) return true;
  int guard = 512;
  while (guard-- > 0 && !disposed_ && playing_ && !audio_eof_) {
    if (last_audio_pts_ms_ >= deadline_ms - 15) break;
    if (!WriteOneAudioSample()) break;
  }
  return guard > 0;
}

bool WmfVideoPlayer::WriteOneAudioSample() {
  ComPtr<IMFSample> audio_sample;
  DWORD flags = 0;
  LONGLONG timestamp = 0;
  HRESULT hr =
      reader_->ReadSample(audio_stream_, 0, nullptr, &flags, &timestamp,
                          audio_sample.GetAddressOf());
  if (FAILED(hr)) {
    Emit(PlayerEvent{PlayerEvent::Type::kError, 0, 0, 0, false,
                     HResultToString(hr)});
    return false;
  }
  if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
    audio_eof_ = true;
    return false;
  }
  if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
    return false;
  }
  if (!audio_sample) return false;
  if (timestamp / 10000 < seek_target_ms_) return true;

  ComPtr<IMFMediaBuffer> media_buffer;
  if (FAILED(audio_sample->ConvertToContiguousBuffer(&media_buffer))) {
    return false;
  }
  BYTE* data = nullptr;
  DWORD length = 0;
  if (FAILED(media_buffer->Lock(&data, nullptr, &length))) return false;
  const bool ok = audio_.Write(data, length);
  media_buffer->Unlock();
  if (ok && timestamp >= 0) {
    last_audio_pts_ms_ = static_cast<int64_t>(timestamp / 10000);
    position_ms_ = last_audio_pts_ms_;
  }
  return ok;
}

bool WmfVideoPlayer::ReadVideoSample(ComPtr<IMFSample>* sample,
                                     bool* end_of_stream,
                                     bool* type_changed) {
  DWORD flags = 0;
  LONGLONG timestamp = 0;
  HRESULT hr =
      reader_->ReadSample(video_stream_, 0, nullptr, &flags, &timestamp,
                          sample->GetAddressOf());
  if (FAILED(hr)) {
    Emit(PlayerEvent{PlayerEvent::Type::kError, 0, 0, 0, false,
                     HResultToString(hr)});
    return false;
  }
  *type_changed = (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) != 0;
  *end_of_stream = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
  return true;
}

void WmfVideoPlayer::RefreshVideoOutput() {
  // Both playback and a paused seek can change the decoder output format.
  ComPtr<IMFMediaType> actual_type;
  if (FAILED(reader_->GetCurrentMediaType(video_stream_, &actual_type))) return;
  UINT32 width = 0, height = 0;
  MFGetAttributeSize(actual_type.Get(), MF_MT_FRAME_SIZE, &width, &height);
  if (width == 0 || height == 0) return;

  std::lock_guard<std::mutex> lock(frame_mutex_);
  video_width_ = width;
  video_height_ = height;
  UINT32 stride_raw = 0;
  actual_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_raw);
  const int32_t stride = static_cast<int32_t>(stride_raw);
  bottom_up_ = stride < 0;
  frame_byte_stride_ = std::max<int64_t>(
      std::abs(static_cast<int64_t>(stride)), video_width_ * 4);
  const int64_t buffer_bytes = video_width_ * 4 * height;
  for (FrameSlot& slot : frame_slots_) {
    slot.data.resize(static_cast<size_t>(buffer_bytes));
    slot.width = width;
    slot.height = height;
  }
}

void WmfVideoPlayer::PresentPaced(const ComPtr<IMFSample>& sample, LONGLONG pts) {
  if (first_video_frame_) {
    first_video_frame_ = false;
    last_video_pts_ = pts;
    PresentFrame(sample);
    return;
  }
  const int64_t delta = pts - last_video_pts_;
  last_video_pts_ = pts;
  if (delta > 0) {
    const double interval_ms =
        static_cast<double>(delta) / 10000.0 / speed_;
    if (interval_ms > 2.0) {
      Sleep(static_cast<DWORD>(interval_ms));
    }
  }
  if (!disposed_ && playing_) {
    PresentFrame(sample);
  }
}

void WmfVideoPlayer::PresentFrame(const ComPtr<IMFSample>& sample) {
  if (video_width_ <= 0 || video_height_ <= 0) return;
  std::lock_guard<std::mutex> lock(frame_mutex_);
  const size_t slot = frame_slot_index_;
  if (!ConvertSampleToFrame(sample, slot)) return;
  frame_slot_index_ = (frame_slot_index_ + 1) % kFrameSlots;
  frame_generation_.store(frame_generation_.load() + 1);
  if (textures_) {
    // The engine must be told from the platform thread, mirroring Emit.
    auto self = shared_from_this();
    poster_->Post([self]() {
      if (self->disposed_) return;
      self->textures_->MarkTextureFrameAvailable(self->texture_id_);
    });
  }
}

bool WmfVideoPlayer::ConvertSampleToFrame(const ComPtr<IMFSample>& sample,
                                          size_t slot) {
  // Called with frame_mutex_ already held by [PresentFrame].
  ComPtr<IMFMediaBuffer> media_buffer;
  if (FAILED(sample->ConvertToContiguousBuffer(&media_buffer))) return false;

  FrameSlot& frame = frame_slots_[slot];
  frame.width = video_width_;
  frame.height = video_height_;
  const int64_t row_bytes = video_width_ * 4;
  if (frame.data.size() != static_cast<size_t>(row_bytes * video_height_)) {
    frame.data.resize(static_cast<size_t>(row_bytes * video_height_));
  }

  ComPtr<IMF2DBuffer> buffer_2d;
  if (SUCCEEDED(media_buffer.As(&buffer_2d))) {
    BYTE* data = nullptr;
    LONG pitch = 0;
    if (FAILED(buffer_2d->Lock2D(&data, &pitch))) return false;
    // Lock2D returns the top scanline and a signed pitch. A negative pitch
    // must be followed as-is; its pointer is already adjusted by the buffer.
    CopyRowsToFrame(data, pitch, &frame);
    buffer_2d->Unlock2D();
  } else {
    BYTE* data = nullptr;
    DWORD length = 0;
    if (FAILED(media_buffer->Lock(&data, nullptr, &length))) return false;
    const int64_t source_bytes = frame_byte_stride_ * video_height_;
    if (static_cast<int64_t>(length) < source_bytes) {
      media_buffer->Unlock();
      return false;
    }
    CopyRowsToFrame(bottom_up_ ? data +
                        (video_height_ - 1) * frame_byte_stride_ : data,
                    bottom_up_ ? -frame_byte_stride_ : frame_byte_stride_,
                    &frame);
    media_buffer->Unlock();
  }
  return true;
}

void WmfVideoPlayer::CopyRowsToFrame(const BYTE* src, int64_t src_stride,
                                     FrameSlot* frame) {
  const int64_t height = video_height_;
  const int64_t row_bytes = video_width_ * 4;
  if (height <= 0 || row_bytes <= 0 || !src) return;
  for (int64_t row = 0; row < height; ++row) {
    BYTE* destination = frame->data.data() + row * row_bytes;
    memcpy(destination, src + row * src_stride,
           static_cast<size_t>(row_bytes));
    // MFVideoFormat_RGB32's fourth byte is undefined; Flutter needs opaque
    // alpha for the same pixels rendered by the GDI PiP window.
    for (int64_t column = 0; column < video_width_; ++column)
      destination[column * 4 + 3] = 255;
  }
}

void WmfVideoPlayer::HandleEndOfStream() {
  if (looping_) {
    DoSeek(0);
    return;
  }
  playing_ = false;
  audio_.Stop();
  Emit(PlayerEvent{PlayerEvent::Type::kCompleted});
  Emit(PlayerEvent{PlayerEvent::Type::kIsPlayingStateUpdate, 0, 0, 0, false,
                   ""});
}

void WmfVideoPlayer::DoSeek(int64_t position_ms) {
  if (!reader_ || !ready_.load() || disposed_.load()) return;
  const int64_t safe_maximum = std::numeric_limits<int64_t>::max() / 10000;
  const int64_t maximum = duration_ms_ > 0
                              ? std::min(duration_ms_, safe_maximum)
                              : safe_maximum;
  position_ms = std::clamp<int64_t>(position_ms, 0, maximum);
  PROPVARIANT position;
  PropVariantInit(&position);
  position.vt = VT_I8;
  position.hVal.QuadPart = position_ms * 10000;
  const HRESULT seek_result = reader_->SetCurrentPosition(GUID_NULL, position);
  PropVariantClear(&position);
  if (FAILED(seek_result)) {
    Emit(PlayerEvent{PlayerEvent::Type::kError, 0, 0, 0, false,
                     HResultToString(seek_result)});
    return;
  }
  reader_->Flush(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS));

  video_eof_ = video_stream_ == static_cast<DWORD>(-1);
  audio_eof_ = audio_stream_ == static_cast<DWORD>(-1);
  first_video_frame_ = true;
  was_buffering_ = false;
  last_audio_pts_ms_ = position_ms;
  seek_target_ms_ = position_ms;
  position_ms_ = position_ms;
  audio_.ResetClock();

  if (playing_.load() || video_eof_) return;
  // Seeking a paused player must update its picture without briefly playing
  // audio or publishing a play/pause state change. Decode the keyframe preroll
  // on this pump thread, then present the first frame at or after the target.
  ComPtr<IMFSample> preview;
  while (!disposed_.load()) {
    {
      std::lock_guard<std::mutex> lock(command_mutex_);
      if (!commands_.empty() &&
          (commands_.front().type == CommandType::kSeek ||
           commands_.front().type == CommandType::kSeekBy)) {
        return;  // A newer seek will produce the requested preview instead.
      }
    }
    ComPtr<IMFSample> sample;
    bool end_of_stream = false;
    bool type_changed = false;
    if (!ReadVideoSample(&sample, &end_of_stream, &type_changed)) return;
    if (type_changed) RefreshVideoOutput();
    if (disposed_.load()) return;
    if (sample) {
      LONGLONG timestamp = 0;
      if (SUCCEEDED(sample->GetSampleTime(&timestamp))) {
        preview = sample;
        if (timestamp / 10000 >= position_ms) {
          PresentFrame(preview);
          return;
        }
      }
    }
    if (end_of_stream) {
      video_eof_ = true;
      // An exact seek to the duration has no later frame. Keep the last valid
      // image while the play head remains at the requested end position.
      if (preview) PresentFrame(preview);
      return;
    }
  }
}

bool WmfVideoPlayer::CopyCurrentFrame(std::vector<uint8_t>* data,
                                      int64_t* width, int64_t* height,
                                      int64_t* stride) {
  std::lock_guard<std::mutex> lock(frame_mutex_);
  const size_t slot = (frame_slot_index_ - 1 + kFrameSlots) % kFrameSlots;
  const FrameSlot& frame = frame_slots_[slot];
  if (frame.data.empty() || frame.width <= 0 || frame.height <= 0) {
    return false;
  }
  *data = frame.data;
  *width = frame.width;
  *height = frame.height;
  *stride = frame.width * 4;
  return true;
}

std::string WmfVideoPlayer::HResultString(HRESULT hr) {
  return HResultToString(hr);
}

}  // namespace video_player_custom
