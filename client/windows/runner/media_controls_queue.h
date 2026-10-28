#ifndef RUNNER_MEDIA_CONTROLS_QUEUE_H_
#define RUNNER_MEDIA_CONTROLS_QUEUE_H_

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>

// SMTC callbacks run on a system worker. The window thread only tries the lock;
// a producer always posts its wake-up after releasing it, so it never needs to
// wait for a callback or poll for commands.
class MediaControlsQueue {
 public:
  struct Command {
    const char* action = nullptr;
    int64_t position_ms = -1;
  };
  static constexpr size_t kCapacity = 32;
  using Batch = std::array<Command, kCapacity>;

  explicit MediaControlsQueue(int64_t id, int64_t revision = 0)
      : session_id(id), pause_revision(revision) {}

  bool Push(Command command) {
    if (!active.load()) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!active.load() || size_ == kCapacity) return false;
    pending_[size_++] = command;
    return true;
  }

  size_t Take(Batch& commands) {
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock() || !active.load()) return 0;
    const auto count = size_;
    for (size_t index = 0; index < count; ++index) {
      commands[index] = pending_[index];
    }
    size_ = 0;
    return count;
  }

  const int64_t session_id;
  const int64_t pause_revision;
  std::atomic<bool> active{true};

 private:
  std::mutex mutex_;
  Batch pending_{};
  size_t size_ = 0;
};

#endif
