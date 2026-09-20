#ifndef PLUGIN_LINUX_GST_VIDEO_PLAYER_H_
#define PLUGIN_LINUX_GST_VIDEO_PLAYER_H_

#include <flutter/texture_registrar.h>

#include <gst/app/gstappsink.h>
#include <gst/gst.h>

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

/// An event emitted by [GstVideoPlayer] towards the Flutter side.
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

/// A video player for Linux built directly on GStreamer (playbin).
///
/// playbin handles demuxing, decoding and audio rendering; video frames are
/// pulled from an appsink (RGBA, newest-only) and pushed into a Flutter
/// pixel-buffer texture. Video is paced against the wall clock so that the
/// (clock-driven) audio stays in sync.
class GstVideoPlayer {
 public:
  using EventCallback = std::function<void(const PlayerEvent&)>;

  /// |textures| must outlive the player.
  GstVideoPlayer(std::shared_ptr<flutter::TextureRegistrar> textures,
                 EventCallback on_event);
  ~GstVideoPlayer();

  /// Spawns the pump thread and opens |url| on it. On failure returns false and
  /// sets |error|.
  bool Initialize(const std::string& url, std::string* error);

  /// Stops the pump thread and releases all native resources. Idempotent.
  void Dispose();

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
  enum class CommandType {
    kNone,
    kPlay,
    kPause,
    kSeek,
    kSetVolume,
    kSetRate,
    kDispose,
  };

  struct Command {
    CommandType type;
    int64_t position_ms = 0;
    float volume = 0.0f;
    float rate = 0.0f;
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
  bool BuildPipeline(const std::string& uri, std::string* error);
  void ReadOneFrame();
  void PresentSample(GstSample* sample);
  void CopyBufferIntoFrame(GstBuffer* buffer, size_t slot);
  void HandleEos();
  void HandleError(GstMessage* message);
  void DoSeek(int64_t position_ms);
  void ApplyRate();
  void Emit(PlayerEvent event);
  void PostCommand(Command command);
  Command PopCommand();
  void UpdatePosition();
  void QueryDuration();

  std::shared_ptr<flutter::TextureRegistrar> textures_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;

  EventCallback on_event_;
  std::thread pump_thread_;
  std::atomic<bool> disposed_ = false;
  std::atomic<bool> ready_ = false;
  std::atomic<bool> dispose_started_ = false;
  std::string url_;

  // Setup result, published to the caller of [Initialize].
  std::mutex ready_mutex_;
  std::condition_variable ready_cv_;
  bool setup_failed_ = false;
  std::string setup_error_;

  std::mutex command_mutex_;
  std::condition_variable command_cv_;
  std::deque<Command> commands_;

  // ---- GStreamer state (control thread only) ----
  GstElement* playbin_ = nullptr;
  GstElement* video_bin_ = nullptr;
  GstAppSink* appsink_ = nullptr;
  GstBus* bus_ = nullptr;

  // Playback state.
  bool playing_ = false;
  bool pipeline_started_ = false;
  bool looping_ = false;
  float speed_ = 1.0f;
  float volume_ = 1.0f;
  int64_t duration_ms_ = 0;
  int64_t position_ms_ = 0;
  bool was_buffering_ = false;
  bool initialized_emitted_ = false;

  // Video pacing state.
  bool first_video_frame_pending_ = true;
  int64_t first_pts_ns_ = 0;
  int64_t first_wall_us_ = 0;
  int64_t last_sample_us_ = 0;

  // ---- Texture / frame state ----
  static constexpr size_t kFrameSlots = 3;
  std::mutex frame_mutex_;
  std::array<FrameSlot, kFrameSlots> frame_slots_;
  size_t frame_slot_index_ = 0;
  FlutterDesktopPixelBuffer pixel_buffer_ = {};
};

}  // namespace video_player_custom

#endif  // PLUGIN_LINUX_GST_VIDEO_PLAYER_H_