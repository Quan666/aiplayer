#ifndef RUNNER_SYSTEM_PROXY_SIGNAL_H_
#define RUNNER_SYSTEM_PROXY_SIGNAL_H_

#include <windows.h>
#include <winhttp.h>
#include <atomic>

// A manual-reset event remembers cancellation/completion even if it happens
// immediately before the worker starts waiting. The platform thread never
// waits for the worker's mutex or for WinHTTP to deliver a callback.
class SystemProxySignal {
 public:
  SystemProxySignal() : event_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~SystemProxySignal() { if (event_) CloseHandle(event_); }
  SystemProxySignal(const SystemProxySignal&) = delete;
  SystemProxySignal& operator=(const SystemProxySignal&) = delete;

  bool valid() const { return event_ != nullptr; }
  bool cancelled() const { return cancelled_.load(); }
  void Cancel() {
    cancelled_ = true;
    SetEvent(event_);
  }
  void Complete(DWORD status) {
    status_ = status;
    SetEvent(event_);
  }
  DWORD Wait(DWORD timeout_ms = 5000) const {
    const DWORD waited = WaitForSingleObject(event_, timeout_ms);
    if (cancelled()) return ERROR_WINHTTP_OPERATION_CANCELLED;
    if (waited == WAIT_TIMEOUT) return ERROR_WINHTTP_TIMEOUT;
    if (waited != WAIT_OBJECT_0) return GetLastError();
    return status_.load();
  }

 private:
  HANDLE event_;
  std::atomic<bool> cancelled_{false};
  std::atomic<DWORD> status_{ERROR_IO_PENDING};
};

#endif
