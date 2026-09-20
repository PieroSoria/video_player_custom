// Linux desktop video backend built directly on GStreamer.
//
// A playbin demuxes and decodes the media, drives the audio through the
// default (clock-synced) audio sink and feeds decoded video frames to an
// appsink. The appsink (RGBA, drop-oldest) is drained by the control thread,
// which paces frames against the wall clock and pushes them into a Flutter
// pixel-buffer texture. No third-party playback packages are used.

#include "gst_video_player.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <string>
#include <utility>

namespace video_player_custom {

namespace {

// GLib monotonic clock in microseconds.
int64_t MonotonicUs() { return static_cast<int64_t>(g_get_monotonic_time()); }

}  // namespace

// ---------------------------------------------------------------------------
// GstVideoPlayer
// ---------------------------------------------------------------------------

GstVideoPlayer::GstVideoPlayer(
    std::shared_ptr<flutter::TextureRegistrar> textures,
    std::shared_ptr<TaskPoster> poster,
    EventCallback on_event)
    : textures_(std::move(textures)),
      poster_(std::move(poster)),
      on_event_(std::move(on_event)) {
  pixel_buffer_.buffer = nullptr;
  pixel_buffer_.width = 0;
  pixel_buffer_.height = 0;
  pixel_buffer_.release_callback = nullptr;
  pixel_buffer_.release_context = nullptr;
}

GstVideoPlayer::~GstVideoPlayer() { Dispose(); }

bool GstVideoPlayer::Initialize(const std::string& url, std::string* error) {
  ready_ = false;
  setup_failed_ = false;
  url_ = url;
  pump_thread_ = std::thread([this]() { PumpLoop(); });

  std::unique_lock<std::mutex> lock(ready_mutex_);
  const bool done = ready_cv_.wait_for(lock, std::chrono::seconds(30), [this]() {
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

void GstVideoPlayer::Dispose() {
  if (dispose_started_.exchange(true)) return;
  disposed_ = true;
  PostCommand(Command{CommandType::kDispose});
  if (pump_thread_.joinable()) pump_thread_.join();
}

void GstVideoPlayer::Play() { PostCommand(Command{CommandType::kPlay}); }

void GstVideoPlayer::Pause() { PostCommand(Command{CommandType::kPause}); }

void GstVideoPlayer::SeekTo(int64_t position_ms) {
  PostCommand(Command{CommandType::kSeek, position_ms});
}

void GstVideoPlayer::SetLooping(bool looping) { looping_ = looping; }

void GstVideoPlayer::SetVolume(float volume) {
  volume_ = std::clamp(volume, 0.0f, 1.0f);
  PostCommand(Command{CommandType::kSetVolume, 0, volume_});
}

void GstVideoPlayer::SetPlaybackSpeed(float speed) {
  speed_ = speed > 0.0f ? speed : 1.0f;
  PostCommand(Command{CommandType::kSetRate, 0, 0.0f, speed_});
}

int64_t GstVideoPlayer::GetPositionMs() const { return position_ms_; }

int64_t GstVideoPlayer::GetBufferedPositionMs() const {
  if (duration_ms_ > 0) return duration_ms_;
  return position_ms_;
}

void GstVideoPlayer::PostCommand(Command command) {
  {
    std::lock_guard<std::mutex> lock(command_mutex_);
    commands_.push_back(command);
  }
  command_cv_.notify_all();
}

GstVideoPlayer::Command GstVideoPlayer::PopCommand() {
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

void GstVideoPlayer::Emit(PlayerEvent event) {
  if (!poster_) {
    if (on_event_) on_event_(event);
    return;
  }
  // Channel sends must happen on the platform thread; the control thread runs
  // on its own thread. Holding |self| keeps the player alive until the task
  // runs.
  auto self = shared_from_this();
  poster_->Post(
      [self, event]() { if (self->on_event_) self->on_event_(event); });
}

void GstVideoPlayer::PumpLoop() {
  std::string error;
  if (!BuildPipeline(url_, &error)) {
    {
      std::lock_guard<std::mutex> lock(ready_mutex_);
      setup_failed_ = true;
      setup_error_ = error;
      ready_cv_.notify_all();
    }
  } else {
    {
      std::lock_guard<std::mutex> lock(ready_mutex_);
      ready_ = true;
      ready_cv_.notify_all();
    }
  }

  while (!disposed_) {
    Command command = PopCommand();
    if (command.type == CommandType::kDispose) break;

    switch (command.type) {
      case CommandType::kPlay:
        if (!playing_ && playbin_) {
          gst_element_set_state(GST_ELEMENT(playbin_), GST_STATE_PLAYING);
          playing_ = true;
          pipeline_started_ = true;
          first_video_frame_pending_ = true;
          if (speed_ != 1.0f) ApplyRate();
          Emit(PlayerEvent{PlayerEvent::Type::kIsPlayingStateUpdate, 0, 0, 0,
                           true, ""});
        }
        break;
      case CommandType::kPause:
        if (playing_ && playbin_) {
          gst_element_set_state(GST_ELEMENT(playbin_), GST_STATE_PAUSED);
          playing_ = false;
          Emit(PlayerEvent{PlayerEvent::Type::kIsPlayingStateUpdate, 0, 0, 0,
                           false, ""});
        }
        break;
      case CommandType::kSeek:
        DoSeek(command.position_ms);
        break;
      case CommandType::kSetVolume:
        if (playbin_) {
          g_object_set(G_OBJECT(playbin_), "volume", (double)volume_, nullptr);
        }
        break;
      case CommandType::kSetRate:
        if (playing_ && playbin_) ApplyRate();
        break;
      case CommandType::kNone:
        break;
    }

    if (disposed_ || !playing_) continue;

    // Check the bus for errors / end-of-stream.
    if (bus_) {
      GstMessage* message = gst_bus_timed_pop_filtered(
          bus_, static_cast<GstClockTime>(GST_MSECOND * 20),
          static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
      if (message) {
        switch (GST_MESSAGE_TYPE(message)) {
          case GST_MESSAGE_ERROR:
            HandleError(message);
            gst_message_unref(message);
            if (disposed_ || !playing_) continue;
            break;
          case GST_MESSAGE_EOS:
            HandleEos();
            gst_message_unref(message);
            if (disposed_ || !playing_) continue;
            break;
          default:
            gst_message_unref(message);
            break;
        }
      }
    }

    UpdatePosition();
    ReadOneFrame();

    // Audio-only media produce no video frames; emit the initialized event
    // based on the duration once the pipeline has had a chance to preroll.
    if (!initialized_emitted_ && pipeline_started_ && last_sample_us_ != 0 &&
        (MonotonicUs() - last_sample_us_) > 1000000) {
      QueryDuration();
      Emit(PlayerEvent{PlayerEvent::Type::kInitialized, duration_ms_, 0, 0,
                       false, ""});
      initialized_emitted_ = true;
    }
  }

  if (playbin_) {
    gst_element_set_state(GST_ELEMENT(playbin_), GST_STATE_NULL);
  }
  if (bus_) {
    gst_object_unref(bus_);
    bus_ = nullptr;
  }
  if (appsink_) {
    gst_object_unref(appsink_);
    appsink_ = nullptr;
  }
  if (video_bin_) {
    gst_object_unref(video_bin_);
    video_bin_ = nullptr;
  }
  if (playbin_) {
    gst_object_unref(playbin_);
    playbin_ = nullptr;
  }
}

bool GstVideoPlayer::BuildPipeline(const std::string& uri,
                                   std::string* error) {
  // Video sink: videoconvert ! videoscale ! appsink (RGBA, keep newest).
  GError* parse_error = nullptr;
  video_bin_ = gst_parse_launch(
      "videoconvert ! videoscale ! appsink name=vsink max-buffers=1 "
      "drop=true sync=false qos=false "
      "caps=\"video/x-raw,format=RGBA\"",
      &parse_error);
  if (!video_bin_) {
    if (error && parse_error) *error = parse_error->message;
    if (error && !parse_error) *error = "Failed to create the video sink.";
    g_clear_error(&parse_error);
    return false;
  }
  appsink_ = reinterpret_cast<GstAppSink*>(
      gst_bin_get_by_name(GST_BIN(video_bin_), "vsink"));
  if (!appsink_) {
    if (error) *error = "Failed to locate the video appsink.";
    return false;
  }

  playbin_ = gst_element_factory_make("playbin", "player");
  if (!playbin_) {
    if (error) *error = "Failed to create the GStreamer playbin element.";
    return false;
  }

  g_object_set(G_OBJECT(playbin_), "uri", uri.c_str(), nullptr);
  g_object_set(G_OBJECT(playbin_), "video-sink", video_bin_, nullptr);
  g_object_set(G_OBJECT(playbin_), "volume", (double)volume_, nullptr);

  bus_ = gst_element_get_bus(GST_ELEMENT(playbin_));

  // Start in the paused state so the pipeline prerolls; Play() moves on.
  GstStateChangeReturn state_result =
      gst_element_set_state(GST_ELEMENT(playbin_), GST_STATE_PAUSED);
  if (state_result == GST_STATE_CHANGE_FAILURE) {
    if (error) *error = "The GStreamer pipeline failed to start.";
    return false;
  }

  QueryDuration();

  // --- Texture --------------------------------------------------------------
  texture_ = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture(
          [this](size_t /*width*/,
                 size_t /*height*/) -> const FlutterDesktopPixelBuffer* {
            std::lock_guard<std::mutex> lock(frame_mutex_);
            const size_t slot =
                (frame_slot_index_ + kFrameSlots - 1) % kFrameSlots;
            const FrameSlot& frame = frame_slots_[slot];
            pixel_buffer_.buffer =
                frame.data.empty() ? nullptr : frame.data.data();
            pixel_buffer_.width = frame.width;
            pixel_buffer_.height = frame.height;
            return &pixel_buffer_;
          }));
  texture_id_ = textures_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    if (error) *error = "Failed to register the video texture.";
    return false;
  }
  return true;
}

void GstVideoPlayer::ReadOneFrame() {
  // The appsink only ever holds the newest frame, so pacing naturally skips
  // frames when audio is behind.
  GstSample* sample =
      gst_app_sink_try_pull_sample(appsink_, static_cast<GstClockTime>(0));
  if (sample) {
    const bool was_starved = was_buffering_;
    was_buffering_ = false;
    last_sample_us_ = MonotonicUs();
    if (was_starved) {
      Emit(PlayerEvent{PlayerEvent::Type::kBufferingEnd});
    }
    PresentSample(sample);
    gst_sample_unref(sample);
    if (disposed_ || !playing_) return;
  } else if (playing_ && initialized_emitted_) {
    // No frame available right now; only report buffering after a sustained
    // starvation window so normal frame pacing doesn't flicker the indicator.
    if (!was_buffering_ && last_sample_us_ != 0 &&
        (MonotonicUs() - last_sample_us_) > 300000) {
      was_buffering_ = true;
      Emit(PlayerEvent{PlayerEvent::Type::kBufferingStart});
    }
  }
}

void GstVideoPlayer::PresentSample(GstSample* sample) {
  GstCaps* caps = gst_sample_get_caps(sample);
  gint width = 0;
  gint height = 0;
  if (caps) {
    GstStructure* structure = gst_caps_get_structure(caps, 0);
    if (structure) {
      gst_structure_get_int(structure, "width", &width);
      gst_structure_get_int(structure, "height", &height);
    }
  }
  if (width <= 0 || height <= 0) return;

  GstBuffer* buffer = gst_sample_get_buffer(sample);
  if (!buffer) return;

  // Emit the initialized event on the first frame.
  if (!initialized_emitted_) {
    QueryDuration();
    Emit(PlayerEvent{PlayerEvent::Type::kInitialized, duration_ms_, width,
                     height, false, ""});
    initialized_emitted_ = true;
  }

  // Wall-clock pacing relative to the first frame keeps audio/video in sync
  // without a custom GStreamer clock.
  const gint64 pts = GST_BUFFER_PTS(buffer);
  if (first_video_frame_pending_) {
    first_video_frame_pending_ = false;
    first_pts_ns_ = pts;
    first_wall_us_ = MonotonicUs();
  } else if (pts != GST_CLOCK_TIME_NONE &&
             first_pts_ns_ != GST_CLOCK_TIME_NONE) {
    const int64_t elapsed_us =
        static_cast<int64_t>((pts - first_pts_ns_)) / 1000;
    const int64_t paced_us =
        elapsed_us / static_cast<int64_t>(speed_ > 0.0f ? speed_ : 1.0f);
    const int64_t now_us = MonotonicUs();
    const int64_t target_us = first_wall_us_ + paced_us;
    if (target_us > now_us) {
      g_usleep(static_cast<guint>(target_us - now_us));
    }
  }

  if (disposed_ || !playing_) return;

  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    const size_t slot = frame_slot_index_;
    CopyBufferIntoFrame(buffer, slot);
    frame_slot_index_ = (frame_slot_index_ + 1) % kFrameSlots;
  }
  if (textures_) {
    // The engine must be told from the platform thread, mirroring Emit.
    auto self = shared_from_this();
    poster_->Post([self]() {
      if (self->disposed_) return;
      self->textures_->MarkTextureFrameAvailable(self->texture_id_);
    });
  }
}

void GstVideoPlayer::CopyBufferIntoFrame(GstBuffer* buffer, size_t slot) {
  GstMapInfo info;
  if (!gst_buffer_map(buffer, &info, GST_MAP_READ)) return;

  FrameSlot& frame = frame_slots_[slot];
  GstCaps* caps = gst_buffer_get_caps(buffer);
  gint width = 0;
  gint height = 0;
  if (caps) {
    GstStructure* structure = gst_caps_get_structure(caps, 0);
    if (structure) {
      gst_structure_get_int(structure, "width", &width);
      gst_structure_get_int(structure, "height", &height);
    }
    gst_caps_unref(caps);
  }
  if (width <= 0 || height <= 0 || info.size == 0) {
    gst_buffer_unmap(buffer, &info);
    return;
  }
  size_t needed = static_cast<size_t>(info.size);
  if (frame.data.size() != needed) {
    frame.data.resize(needed);
  }
  std::memcpy(frame.data.data(), info.data, needed);
  frame.width = width;
  frame.height = height;
  gst_buffer_unmap(buffer, &info);
}

void GstVideoPlayer::HandleEos() {
  if (looping_ && playbin_) {
    DoSeek(0);
    return;
  }
  playing_ = false;
  if (playbin_) {
    gst_element_set_state(GST_ELEMENT(playbin_), GST_STATE_PAUSED);
  }
  Emit(PlayerEvent{PlayerEvent::Type::kCompleted});
  Emit(PlayerEvent{PlayerEvent::Type::kIsPlayingStateUpdate, 0, 0, 0, false,
                   ""});
}

void GstVideoPlayer::HandleError(GstMessage* message) {
  GError* gerror = nullptr;
  gchar* debug = nullptr;
  gst_message_parse_error(message, &gerror, &debug);
  std::string text = gerror && gerror->message ? gerror->message : "unknown";
  g_clear_error(&gerror);
  g_free(debug);
  playing_ = false;
  Emit(PlayerEvent{PlayerEvent::Type::kError, 0, 0, 0, false, text});
}

void GstVideoPlayer::DoSeek(int64_t position_ms) {
  if (!playbin_) return;
  if (position_ms < 0) position_ms = 0;
  const gint64 position_ns = position_ms * 1000000;
  const GstSeekFlags flags = static_cast<GstSeekFlags>(
      GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT);
  gst_element_seek_simple(GST_ELEMENT(playbin_), GST_FORMAT_TIME, flags,
                          position_ns);
  first_video_frame_pending_ = true;
  was_buffering_ = false;
  last_sample_us_ = 0;
  position_ms_ = position_ms;
}

void GstVideoPlayer::ApplyRate() {
  if (!playbin_) return;
  gint64 position = 0;
  if (!gst_element_query_position(GST_ELEMENT(playbin_), GST_FORMAT_TIME,
                                  &position)) {
    return;
  }
  const GstSeekFlags flags = static_cast<GstSeekFlags>(
      GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE);
  gst_element_seek(GST_ELEMENT(playbin_), (double)speed_, GST_FORMAT_TIME,
                   flags, GST_SEEK_TYPE_SET, position, GST_SEEK_TYPE_NONE,
                   GST_CLOCK_TIME_NONE);
  first_video_frame_pending_ = true;
}

void GstVideoPlayer::UpdatePosition() {
  if (!playbin_) return;
  gint64 position = 0;
  if (gst_element_query_position(GST_ELEMENT(playbin_), GST_FORMAT_TIME,
                                 &position) &&
      position != GST_CLOCK_TIME_NONE) {
    position_ms_ = position / 1000000;
  }
}

void GstVideoPlayer::QueryDuration() {
  if (!playbin_) return;
  gint64 duration = 0;
  if (gst_element_query_duration(GST_ELEMENT(playbin_), GST_FORMAT_TIME,
                                 &duration) &&
      duration != GST_CLOCK_TIME_NONE) {
    duration_ms_ = duration / 1000000;
  }
}

}  // namespace video_player_custom