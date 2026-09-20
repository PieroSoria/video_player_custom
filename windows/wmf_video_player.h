#ifndef PLUGIN_WINDOWS_WMF_VIDEO_PLAYER_H_
#define PLUGIN_WINDOWS_WMF_VIDEO_PLAYER_H_

#include <flutter/texture_registrar.h>

#include <audioclient.h>
#include <audiopolicy.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace video_player_custom {

using Microsoft::WRL::ComPtr;

/// An event emitted by [WmfVideoPlayer] towards the Flutter side.
struct PlayerEvent {
  enum class Type {
    kInitialized,
    kCompleted,
    kBufferingStart,
    kBufferingEnd,
    kIsPlayingStateUpdate,
    kError,
  };

  Type type = Type::kInitialized;
  int64_t duration_ms = 0;
  int64_t width = 0;
  int64_t height = 0;
  bool is_playing = false;
  std::string message;
};

/// A WASAPI (shared mode) renderer for 16-bit PCM audio.
///
/// Owns the audio endpoint and is the master clock source for playback. It is
/// only touched from the player's pump thread.
class AudioSink {
 public:
  AudioSink() = default;
  ~AudioSink();

  bool Initialize(uint32_t sample_rate, uint32_t channels);
  void Close();

  /// Writes 16-bit PCM from |buffer| (|bytes| long) blocking until the device
  /// has room. Returns false on audio device failure.
  bool Write(const void* buffer, size_t bytes);
  void Start();
  void Stop();

  /// Current play head in milliseconds (0 when not playing).
  int64_t GetPositionMs() const;
  void SetVolume(float volume);

  /// Resets the internal play head, used before replaying after a seek.
  void ResetClock();

 private:
  ComPtr<IMMDevice> device_;
  ComPtr<IAudioClient> client_;
  ComPtr<IAudioRenderClient> render_;
  ComPtr<ISimpleAudioVolume> volume_;
  uint32_t rate_ = 48000;
  uint32_t channels_ = 2;
  uint32_t buffer_frames_ = 0;
  uint64_t frames_written_ = 0;
  float volume_level_ = 1.0f;
  bool started_ = false;
};

/// A video player for Windows built directly on Windows Media Foundation.
///
/// All Media Foundation and WASAPI objects are confined to a single pump
/// thread (initialized as an MTA) so no COM apartment marshalling is needed.
/// Decoded video frames are converted to 32-bit BGRA and pushed into a
/// Flutter pixel-buffer texture; decoded PCM audio is rendered through
/// [AudioSink].
class WmfVideoPlayer {
 public:
  using EventCallback = std::function<void(const PlayerEvent&)>;

  /// |textures| must outlive the player.
  WmfVideoPlayer(std::shared_ptr<flutter::TextureRegistrar> textures,
                 EventCallback on_event);
  ~WmfVideoPlayer();

  /// Spawns the pump thread and opens |url| on it. On failure returns false and
  /// sets |error|.
  bool Initialize(const std::string& url, std::string* error);

  /// Stops the pump thread and releases all native resources. Idempotent.
  void Dispose();

  /// Requests playback of |url| through [Initialize] (idempotent).
  void Play();
  void Pause();
  void SeekTo(int64_t position_ms);
  void SetLooping(bool looping);
  void SetVolume(float volume);
  void SetPlaybackSpeed(float speed);
  int64_t GetPositionMs() const;
  int64_t GetBufferedPositionMs() const;

  int64_t texture_id() const { return texture_id_; }
  bool ready() const { return ready_; }

 private:
  enum class CommandType { kNone, kPlay, kPause, kSeek, kSetVolume, kDispose };

  struct Command {
    CommandType type;
    int64_t position_ms = 0;
    float volume = 0.0f;
  };

  // One frame ring slot handed to the Flutter engine through the texture
  // callback. Slots are recycled, so a buffer referenced by the engine stays
  // valid across a few frame generations.
  struct FrameSlot {
    std::vector<uint8_t> data;
    int64_t width = 0;
    int64_t height = 0;
  };

  void PumpLoop();
  bool SetupMedia(std::string* error);
  void ReadPlayStep();
  bool WriteAudioForDeadline(int64_t deadline_ms);
  bool has_video_stream_audio_deadline(bool has_audio) const;
  bool WriteOneAudioSample();
  bool ReadVideoSample(ComPtr<IMFSample>* sample,
                       bool* end_of_stream,
                       bool* type_changed);
  void PresentPaced(const ComPtr<IMFSample>& sample, LONGLONG pts);
  void PresentFrame(const ComPtr<IMFSample>& sample);
  void HandleEndOfStream();
  void DoSeek(int64_t position_ms);
  bool ConvertSampleToFrame(const ComPtr<IMFSample>& sample, size_t slot);
  void CopyRowsToFrame(const BYTE* src, int64_t src_stride, FrameSlot* frame);
  void Emit(PlayerEvent event);
  void PostCommand(Command command);
  Command PopCommand();
  static std::string HResultString(HRESULT hr);

  std::shared_ptr<flutter::TextureRegistrar> textures_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;

  EventCallback on_event_;
  std::thread pump_thread_;
  std::atomic<bool> disposed_ = false;
  std::atomic<bool> ready_ = false;
  std::atomic<bool> dispose_started_ = false;

  // Setup result, published to the caller of [Initialize].
  std::mutex ready_mutex_;
  std::condition_variable ready_cv_;
  bool setup_failed_ = false;
  std::string setup_error_;

  // The URL opened by [Initialize].
  std::string url_;

  std::mutex command_mutex_;
  std::condition_variable command_cv_;
  std::deque<Command> commands_;

  // ---- Media Foundation state (pump thread only unless noted) ----
  ComPtr<IMFSourceReader> reader_;
  DWORD video_stream_ = static_cast<DWORD>(-1);
  DWORD audio_stream_ = static_cast<DWORD>(-1);
  int64_t duration_ms_ = 0;

  // Video output state.
  int64_t video_width_ = 0;
  int64_t video_height_ = 0;
  int64_t frame_byte_stride_ = 0;
  bool bottom_up_ = false;

  // Audio output state.
  uint32_t audio_rate_ = 48000;
  uint32_t audio_channels_ = 2;
  bool audio_present_ = false;

  // Playback state.
  bool playing_ = false;
  bool looping_ = false;
  float speed_ = 1.0f;
  float volume_ = 1.0f;
  bool video_eof_ = true;
  bool audio_eof_ = true;
  bool first_video_frame_ = true;
  int64_t last_video_pts_ = 0;
  int64_t last_audio_pts_ms_ = 0;
  bool was_buffering_ = false;

  std::atomic<int64_t> position_ms_ = 0;
  std::atomic<int64_t> buffered_ms_ = 0;

  // ---- Texture / frame state ----
  static constexpr size_t kFrameSlots = 3;
  std::mutex frame_mutex_;
  std::array<FrameSlot, kFrameSlots> frame_slots_;
  size_t frame_slot_index_ = 0;
  FlutterDesktopPixelBuffer pixel_buffer_ = {};
  AudioSink audio_;
};

}  // namespace video_player_custom

#endif  // PLUGIN_WINDOWS_WMF_VIDEO_PLAYER_H_