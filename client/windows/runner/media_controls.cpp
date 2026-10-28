#include "media_controls.h"

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <optional>
#include <string>

#include "media_controls_queue.h"

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Media;

const EncodableValue* Argument(const EncodableMap& arguments, const char* key) {
  const auto found = arguments.find(EncodableValue(key));
  return found == arguments.end() ? nullptr : &found->second;
}

int64_t Integer(const EncodableMap& arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  if (!value) return 0;
  if (const auto* number = std::get_if<int64_t>(value)) return *number;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  return 0;
}

bool Boolean(const EncodableMap& arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  const auto* boolean = value ? std::get_if<bool>(value) : nullptr;
  return boolean && *boolean;
}

std::string Title(const EncodableMap& arguments) {
  const auto* value = Argument(arguments, "title");
  const auto* title = value ? std::get_if<std::string>(value) : nullptr;
  return title ? *title : std::string();
}

double Speed(const EncodableMap& arguments) {
  const auto* value = Argument(arguments, "speed");
  const auto* speed = value ? std::get_if<double>(value) : nullptr;
  return speed && std::isfinite(*speed) && *speed > 0 ? *speed : 1.0;
}

winrt::Windows::Foundation::TimeSpan Time(int64_t milliseconds) {
  constexpr int64_t kMaximum = std::numeric_limits<int64_t>::max() / 10000;
  return winrt::Windows::Foundation::TimeSpan{
      std::clamp<int64_t>(milliseconds, 0, kMaximum) * 10000};
}

const char* Action(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play: return "play";
    case SystemMediaTransportControlsButton::Pause: return "pause";
    case SystemMediaTransportControlsButton::Stop: return "stop";
    case SystemMediaTransportControlsButton::Next: return "next";
    case SystemMediaTransportControlsButton::Previous: return "previous";
    case SystemMediaTransportControlsButton::FastForward: return "seekForward";
    case SystemMediaTransportControlsButton::Rewind: return "seekBackward";
    default: return nullptr;
  }
}

struct Apartment {
  Apartment() { winrt::init_apartment(winrt::apartment_type::single_threaded); }
  ~Apartment() { winrt::uninit_apartment(); }
};
}  // namespace

struct MediaControlsHandler::State {
  State(HWND handle, int64_t session_id, int64_t pause_revision)
      : window(handle), commands(session_id, pause_revision) {}

  void Post(MediaControlsQueue::Command command) {
    commands.Push(command);
    // Even a full batch needs a wake-up if the consumer just missed our lock.
    if (commands.active.load() && !wake_pending.exchange(true)) {
      // No pointer is put in the message: a late callback cannot leak a payload
      // or dereference a destroyed handler/window if shutdown races this post.
      if (!PostMessage(window, MediaControlsHandler::kCommandMessage, 0, 0)) {
        wake_pending = false;
      }
    }
  }

  const HWND window;
  MediaControlsQueue commands;
  std::atomic<bool> wake_pending{false};
};

struct MediaControlsHandler::Native {
  explicit Native(HWND window) {
    const auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls)));
    controls.IsEnabled(false);
  }

  // Destroy all WinRT references before balancing the apartment initialization.
  Apartment apartment;
  SystemMediaTransportControls controls{nullptr};
  SystemMediaTransportControls::ButtonPressed_revoker buttons;
  SystemMediaTransportControls::PlaybackPositionChangeRequested_revoker seeks;
  std::optional<std::string> title;
};

MediaControlsHandler::MediaControlsHandler(
    flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "app.aiplayer/media_controls",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* arguments = call.arguments()
        ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    if (call.method_name() != "update" && call.method_name() != "clear") {
      result->NotImplemented();
      return;
    }
    if (!arguments || Integer(*arguments, "sessionId") <= 0) {
      result->Error("invalid_arguments", "Missing media session identity");
      return;
    }
    try {
      if (call.method_name() == "clear") {
        const auto cleared = Integer(*arguments, "sessionId");
        cleared_session_id_ = std::max(cleared_session_id_, cleared);
        if (cleared == session_id_) Release();
      } else {
        Update(*arguments);
      }
      result->Success();
    } catch (const winrt::hresult_error& error) {
      Release();
      result->Error("media_controls_unavailable", winrt::to_string(error.message()));
    }
  });
}

MediaControlsHandler::~MediaControlsHandler() {
  channel_->SetMethodCallHandler(nullptr);
  Release();
}

void MediaControlsHandler::Update(const EncodableMap& arguments) {
  const auto session_id = Integer(arguments, "sessionId");
  if (session_id < session_id_ || session_id <= cleared_session_id_) return;
  if (session_id != session_id_) {
    Release();
    session_id_ = session_id;
  }
  if (!Boolean(arguments, "active")) {
    Release();
    return;
  }
  const auto pause_revision = Integer(arguments, "pauseRevision");
  if (state_ && state_->commands.pause_revision != pause_revision) {
    // A callback already running must retain its old revision even when the
    // app has returned to the foreground before its command reaches Dart.
    Release();
  }
  if (!native_) {
    native_ = std::make_unique<Native>(window_);
    state_ = std::make_shared<State>(window_, session_id_, pause_revision);
    const std::weak_ptr<State> weak = state_;
    native_->buttons = native_->controls.ButtonPressed(winrt::auto_revoke,
        [weak](const auto&, const SystemMediaTransportControlsButtonPressedEventArgs& args) {
          if (const auto state = weak.lock()) {
            const auto action = Action(args.Button());
            if (action) state->Post({action, -1});
          }
        });
    native_->seeks = native_->controls.PlaybackPositionChangeRequested(winrt::auto_revoke,
        [weak](const auto&, const PlaybackPositionChangeRequestedEventArgs& args) {
          if (const auto state = weak.lock()) {
            const auto milliseconds = std::chrono::duration_cast<
                std::chrono::milliseconds>(args.RequestedPlaybackPosition()).count();
            state->Post({"seek", std::max<int64_t>(0, milliseconds)});
          }
        });
  }
  const auto& controls = native_->controls;
  const auto title = Title(arguments);
  if (!native_->title || title != *native_->title) {
    const auto display = controls.DisplayUpdater();
    display.Type(MediaPlaybackType::Video);
    display.VideoProperties().Title(winrt::to_hstring(title));
    display.Update();
    native_->title = title;
  }
  const auto duration = std::max<int64_t>(0, Integer(arguments, "durationMs"));
  const auto position = std::clamp<int64_t>(Integer(arguments, "positionMs"), 0, duration);
  controls.IsPlayEnabled(true);
  controls.IsPauseEnabled(true);
  controls.IsStopEnabled(true);
  controls.IsNextEnabled(Boolean(arguments, "canGoNext"));
  controls.IsPreviousEnabled(Boolean(arguments, "canGoPrevious"));
  controls.IsFastForwardEnabled(duration > 0);
  controls.IsRewindEnabled(duration > 0);
  controls.PlaybackStatus(Boolean(arguments, "completed") ? MediaPlaybackStatus::Stopped
      : Boolean(arguments, "buffering") ? MediaPlaybackStatus::Changing
      : Boolean(arguments, "playing") ? MediaPlaybackStatus::Playing
      : MediaPlaybackStatus::Paused);
  controls.PlaybackRate(Speed(arguments));
  SystemMediaTransportControlsTimelineProperties timeline;
  timeline.StartTime(Time(0));
  timeline.MinSeekTime(Time(0));
  timeline.Position(Time(position));
  timeline.MaxSeekTime(Time(duration));
  timeline.EndTime(Time(duration));
  controls.UpdateTimelineProperties(timeline);
  controls.IsEnabled(true);
}

void MediaControlsHandler::Release() noexcept {
  // Revocation does not wait for running callbacks. Close their independent
  // state first; they hold no reference to this handler or its MethodChannel.
  if (state_) state_->commands.active = false;
  if (native_) {
    native_->buttons.revoke();
    native_->seeks.revoke();
    try {
      native_->controls.IsEnabled(false);
      native_->controls.PlaybackStatus(MediaPlaybackStatus::Closed);
      const auto display = native_->controls.DisplayUpdater();
      display.ClearAll();
      display.Update();
    } catch (const winrt::hresult_error&) {
      // System controls can disappear during shutdown; still release handlers.
    }
  }
  native_.reset();
  state_.reset();
}

void MediaControlsHandler::DispatchCommands() {
  const auto state = state_;
  if (!state || !state->commands.active.load()) return;
  // Reset before taking the batch. A producer holding the queue lock will post
  // another wake-up after unlocking if Take cannot acquire it immediately.
  state->wake_pending = false;
  MediaControlsQueue::Batch commands;
  const auto count = state->commands.Take(commands);
  for (size_t index = 0; index < count; ++index) {
    if (state != state_ || !state->commands.active.load()) return;
    EncodableMap arguments{
        {EncodableValue("sessionId"), EncodableValue(state->commands.session_id)},
        {EncodableValue("pauseRevision"), EncodableValue(state->commands.pause_revision)},
        {EncodableValue("action"), EncodableValue(commands[index].action)}};
    if (commands[index].position_ms >= 0) {
      arguments[EncodableValue("positionMs")] = EncodableValue(commands[index].position_ms);
    }
    channel_->InvokeMethod("command", std::make_unique<EncodableValue>(arguments));
  }
}
