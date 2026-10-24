// Run in a Windows Developer Command Prompt (no Flutter engine required):
// cl /EHsc /std:c++17 system_proxy_signal_check.cc /Fe:system_proxy_signal_check.exe
#include "../runner/system_proxy_signal.h"
#include <cassert>
#include <future>
#include <iostream>
#include <thread>

int main() {
  // Regression: a cancellation between predicate evaluation and blocking must
  // not disappear. A persistent event also handles cancellation before Wait.
  SystemProxySignal before;
  assert(before.valid());
  before.Cancel();
  assert(before.Wait(0) == ERROR_WINHTTP_OPERATION_CANCELLED);

  SystemProxySignal during;
  std::promise<void> started;
  auto ready = started.get_future();
  auto worker = std::async(std::launch::async, [&] {
    started.set_value();
    return during.Wait();
  });
  ready.wait();
  during.Cancel();
  assert(worker.wait_for(std::chrono::seconds(1)) == std::future_status::ready);
  assert(worker.get() == ERROR_WINHTTP_OPERATION_CANCELLED);

  SystemProxySignal completed;
  completed.Complete(ERROR_SUCCESS);
  assert(completed.Wait(0) == ERROR_SUCCESS);
  // Cancellation takes precedence over late or simultaneous native replies.
  completed.Cancel();
  completed.Complete(ERROR_SUCCESS);
  assert(completed.Wait(0) == ERROR_WINHTTP_OPERATION_CANCELLED);

  SystemProxySignal pending;
  assert(pending.Wait(1) == ERROR_WINHTTP_TIMEOUT);
  std::cout << "Windows system proxy cancellation/completion signals passed.\n";
}
