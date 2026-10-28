#include "../runner/media_controls_queue.h"

#include <cassert>
#include <memory>
#include <thread>
#include <vector>

int main() {
  MediaControlsQueue queue(7);
  MediaControlsQueue::Batch commands;
  for (size_t index = 0; index < MediaControlsQueue::kCapacity; ++index) {
    assert(queue.Push({"seek", static_cast<int64_t>(index)}));
  }
  assert(!queue.Push({"play", -1}));
  assert(queue.Take(commands) == MediaControlsQueue::kCapacity);
  for (size_t index = 0; index < MediaControlsQueue::kCapacity; ++index) {
    assert(commands[index].position_ms == static_cast<int64_t>(index));
  }
  assert(queue.Take(commands) == 0);
  assert(queue.Push({"pause", -1}));
  queue.active = false;
  assert(queue.Take(commands) == 0);
  assert(!queue.Push({"play", -1}));
  assert(queue.session_id == 7);
  assert(queue.pause_revision == 0);

  // Shutdown can invalidate callbacks without waiting for their worker thread.
  auto old_session = std::make_shared<MediaControlsQueue>(8);
  const std::weak_ptr<MediaControlsQueue> late = old_session;
  old_session->active = false;
  assert(!late.lock()->Push({"play", -1}));
  old_session.reset();
  assert(late.expired());

  // Fast background/foreground changes replace callback state even for the
  // same video. An in-flight callback retains the revision at registration.
  auto before_background = std::make_shared<MediaControlsQueue>(9, 0);
  const auto in_flight = before_background;
  assert(in_flight->Push({"play", -1}));
  before_background->active = false;
  before_background.reset();
  MediaControlsQueue after_foreground(9, 1);
  assert(in_flight->session_id == after_foreground.session_id);
  assert(in_flight->pause_revision == 0);
  assert(after_foreground.pause_revision == 1);
  assert(in_flight->Take(commands) == 0);
  assert(!in_flight->Push({"play", -1}));
  assert(after_foreground.Push({"pause", -1}));
  assert(after_foreground.Take(commands) == 1);

  // Concurrent system callbacks keep accepted events intact and bounded. The
  // consumer uses the same nonblocking Take path as the platform window thread.
  MediaControlsQueue concurrent(9);
  std::atomic<size_t> accepted{0};
  std::atomic<int> completed{0};
  std::vector<std::thread> producers;
  for (int producer = 0; producer < 4; ++producer) {
    producers.emplace_back([&concurrent, &accepted, &completed, producer]() {
      for (int sequence = 0; sequence < 2000; ++sequence) {
        if (concurrent.Push({"seek", producer * 2000 + sequence})) ++accepted;
      }
      ++completed;
    });
  }
  std::array<bool, 8000> seen{};
  size_t consumed = 0;
  auto consume = [&](size_t count) {
    for (size_t index = 0; index < count; ++index) {
      const auto position = static_cast<size_t>(commands[index].position_ms);
      assert(position < seen.size());
      assert(!seen[position]);
      seen[position] = true;
    }
    consumed += count;
  };
  while (completed.load() < 4) {
    consume(concurrent.Take(commands));
    std::this_thread::yield();
  }
  for (auto& producer : producers) producer.join();
  consume(concurrent.Take(commands));
  assert(consumed == accepted.load());
  assert(concurrent.Take(commands) == 0);
}
