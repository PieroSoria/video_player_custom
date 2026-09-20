#ifndef PLUGIN_WINDOWS_DESKTOP_TASK_POSTER_H_
#define PLUGIN_WINDOWS_DESKTOP_TASK_POSTER_H_

#include <functional>
#include <memory>

namespace video_player_custom {

/// Runs [Post]ed tasks asynchronously on the thread that created the poster
/// (the Flutter platform thread).
///
/// The player's pump thread must not touch platform-channel sinks or texture
/// registrars directly; the engine requires such calls on the platform thread.
class TaskPoster {
 public:
  virtual ~TaskPoster() = default;

  /// Queues |task| to run on the platform thread, preserving order of
  /// successive [Post] calls.
  virtual void Post(std::function<void()> task) = 0;
};

}  // namespace video_player_custom

#endif  // PLUGIN_WINDOWS_DESKTOP_TASK_POSTER_H_