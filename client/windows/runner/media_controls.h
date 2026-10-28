#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>

class MediaControlsHandler {
 public:
  static constexpr UINT kCommandMessage = WM_APP + 43;
  MediaControlsHandler(flutter::BinaryMessenger* messenger, HWND window);
  ~MediaControlsHandler();
  void DispatchCommands();

 private:
  struct State;
  struct Native;
  void Update(const flutter::EncodableMap& arguments);
  void Release() noexcept;

  HWND window_;
  int64_t session_id_ = 0;
  int64_t cleared_session_id_ = 0;
  std::shared_ptr<State> state_;
  std::unique_ptr<Native> native_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
