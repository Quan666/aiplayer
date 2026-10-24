#ifndef RUNNER_SYSTEM_PROXY_H_
#define RUNNER_SYSTEM_PROXY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <memory>

class SystemProxyHandler {
 public:
  static constexpr UINT kCompletedMessage = WM_APP + 42;
  SystemProxyHandler(flutter::BinaryMessenger* messenger, HWND window);
  ~SystemProxyHandler();
  void Complete();

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
