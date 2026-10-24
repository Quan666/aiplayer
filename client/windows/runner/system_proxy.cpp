#include "system_proxy.h"

#include <winhttp.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>

#include "system_proxy_config.h"
#include "system_proxy_signal.h"
#include "utils.h"

namespace {
using Result = flutter::MethodResult<flutter::EncodableValue>;
struct Request {
  std::string id;
  std::string url;
  std::unique_ptr<Result> result;  // Accessed only on the platform thread.
  SystemProxySignal signal;
  std::string route;
  std::string error;
};

std::wstring Utf16(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (!length) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), &result[0], length);
  return result;
}

struct InternetHandle {
  HINTERNET value = nullptr;
  ~InternetHandle() { if (value) WinHttpCloseHandle(value); }
};

struct UserConfiguration {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG value{};
  ~UserConfiguration() {
    GlobalFree(value.lpszAutoConfigUrl);
    GlobalFree(value.lpszProxy);
    GlobalFree(value.lpszProxyBypass);
  }
};

void CALLBACK ProxyStatus(HINTERNET, DWORD_PTR context, DWORD status,
                          void* information, DWORD) {
  if (!context) return;
  auto* owner = reinterpret_cast<std::shared_ptr<Request>*>(context);
  if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
    delete owner;
    return;
  }
  auto request = *owner;
  if (status == WINHTTP_CALLBACK_STATUS_GETPROXYFORURL_COMPLETE ||
      status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) {
    request->signal.Complete(status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR
        ? static_cast<WINHTTP_ASYNC_RESULT*>(information)->dwError : ERROR_SUCCESS);
  }
}

DWORD AutoRoute(const std::shared_ptr<Request>& request, InternetHandle& session,
                const std::wstring& url,
                const WINHTTP_CURRENT_USER_IE_PROXY_CONFIG& config) {
  if (request->signal.cancelled()) return ERROR_WINHTTP_OPERATION_CANCELLED;
  if (!session.value) {
    session.value = WinHttpOpen(L"aiplayer", WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (!session.value) return GetLastError();
    WinHttpSetTimeouts(session.value, 5000, 5000, 5000, 5000);
    if (WinHttpSetStatusCallback(session.value, ProxyStatus,
        WINHTTP_CALLBACK_FLAG_REQUEST_ERROR |
        WINHTTP_CALLBACK_FLAG_GETPROXYFORURL_COMPLETE |
        WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
      return GetLastError();
    }
  }
  InternetHandle resolver;
  const DWORD created = WinHttpCreateProxyResolver(session.value, &resolver.value);
  if (created != ERROR_SUCCESS) return created;
  // WinHTTP can send callbacks after CloseHandle returns. The context owns a
  // request until HANDLE_CLOSING, including cancellation and engine disposal.
  auto* context = new std::shared_ptr<Request>(request);
  DWORD_PTR context_value = reinterpret_cast<DWORD_PTR>(context);
  if (!WinHttpSetOption(resolver.value, WINHTTP_OPTION_CONTEXT_VALUE,
      &context_value, sizeof(context_value))) {
    delete context;
    return GetLastError();
  }
  WINHTTP_AUTOPROXY_OPTIONS options{};
  // WinHTTP otherwise caches PAC execution results by host. A script can route
  // /public and /private on the same host differently; evaluate every full URL.
  // These flags retain the PAC script/download cache on the reused session.
  options.dwFlags = WINHTTP_AUTOPROXY_NO_CACHE_CLIENT | WINHTTP_AUTOPROXY_NO_CACHE_SVC;
  if (config.lpszAutoConfigUrl && *config.lpszAutoConfigUrl) {
    options.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL;
    options.lpszAutoConfigUrl = config.lpszAutoConfigUrl;
  }
  if (config.fAutoDetect) {
    options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
    options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
  }
  options.fAutoLogonIfChallenged = FALSE;
  if (request->signal.cancelled()) return ERROR_WINHTTP_OPERATION_CANCELLED;
  const DWORD started = WinHttpGetProxyForUrlEx(resolver.value, url.c_str(),
      &options, context_value);
  if (started != ERROR_IO_PENDING && started != ERROR_SUCCESS) return started;
  if (started == ERROR_IO_PENDING) {
    const DWORD status = request->signal.Wait();
    if (status != ERROR_SUCCESS) return status;
  }
  WINHTTP_PROXY_RESULT proxies{};
  const DWORD resolved = WinHttpGetProxyResult(resolver.value, &proxies);
  if (resolved != ERROR_SUCCESS) return resolved;
  for (DWORD i = 0; i < proxies.cEntries; ++i) {
    const auto& entry = proxies.pEntries[i];
    if (i >= 32) {
      request->error = "proxy_resolution_failed";
      break;
    }
    std::string route;
    if (!entry.fProxy) {
      route = "DIRECT";
    } else if (entry.ProxyScheme == INTERNET_SCHEME_HTTP && entry.ProxyPort != 0) {
      auto host = Utf8FromUtf16(entry.pwszProxy);
      if (host.find(':') != std::string::npos && !host.empty() && host.front() != '[') {
        host = "[" + host + "]";
      }
      const auto endpoint = system_proxy_config::Endpoint(host + ":" + std::to_string(entry.ProxyPort));
      if (endpoint.empty()) {
        request->error = "proxy_resolution_failed";
        break;
      }
      route = "PROXY " + endpoint;
    } else {
      request->error = "proxy_unsupported";
      break;
    }
    if (!request->route.empty()) request->route += "; ";
    request->route += route;
  }
  WinHttpFreeProxyResult(&proxies);
  if (request->route.empty() && request->error.empty()) request->error = "proxy_resolution_failed";
  return ERROR_SUCCESS;
}

void Resolve(const std::shared_ptr<Request>& request, InternetHandle& session) {
  const auto url = Utf16(request->url);
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = static_cast<DWORD>(-1);
  parts.dwHostNameLength = static_cast<DWORD>(-1);
  if (url.empty() || !WinHttpCrackUrl(url.c_str(), 0, 0, &parts) ||
      (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS)) {
    request->error = "proxy_unavailable";
    return;
  }
  UserConfiguration config;
  if (!WinHttpGetIEProxyConfigForCurrentUser(&config.value)) {
    request->error = "proxy_resolution_failed";
    return;
  }
  const bool explicit_pac = config.value.lpszAutoConfigUrl && *config.value.lpszAutoConfigUrl;
  if (explicit_pac || config.value.fAutoDetect) {
    const DWORD status = AutoRoute(request, session, url, config.value);
    if (status == ERROR_SUCCESS || request->signal.cancelled()) return;
    // A configured script failing must surface an error. WPAD commonly finds
    // no PAC on ordinary networks; only that absence uses the static settings.
    if (explicit_pac || status != ERROR_WINHTTP_AUTODETECTION_FAILED) {
      request->error = status == ERROR_WINHTTP_TIMEOUT
          ? "proxy_timeout" : "proxy_resolution_failed";
      return;
    }
  }
  const auto host = Utf8FromUtf16(std::wstring(parts.lpszHostName, parts.dwHostNameLength).c_str());
  request->route = system_proxy_config::StaticRoute(
      Utf8FromUtf16(config.value.lpszProxy), Utf8FromUtf16(config.value.lpszProxyBypass),
      parts.nScheme == INTERNET_SCHEME_HTTPS ? "https" : "http", host, parts.nPort);
  if (request->route.empty()) request->error = "proxy_unsupported";
}

const std::string* Argument(const flutter::MethodCall<flutter::EncodableValue>& call,
                            const char* key) {
  const auto* args = call.arguments()
      ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
  if (!args) return nullptr;
  const auto found = args->find(flutter::EncodableValue(key));
  return found == args->end() ? nullptr : std::get_if<std::string>(&found->second);
}
}  // namespace

struct SystemProxyHandler::State {
  // Queue locks cover only small container operations; never OS resolution,
  // callback waits or Flutter replies. The UI never joins a worker thread.
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<std::shared_ptr<Request>> queued;
  std::deque<std::shared_ptr<Request>> completed;
  std::map<std::string, std::shared_ptr<Request>> pending;  // Platform only.
  HWND window;
  bool closed = false;

  static void Worker(const std::shared_ptr<State>& state) {
    // Keep WinHTTP's own PAC cache across requests, but read the user's current
    // settings and evaluate the full URL for every request.
    InternetHandle session;
    for (;;) {
      std::shared_ptr<Request> request;
      {
        std::unique_lock<std::mutex> lock(state->mutex);
        state->changed.wait(lock, [&] { return state->closed || !state->queued.empty(); });
        if (state->closed) return;
        request = state->queued.front();
        state->queued.pop_front();
      }
      if (!request->signal.cancelled()) Resolve(request, session);
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->closed && !request->signal.cancelled()) {
          state->completed.push_back(request);
          PostMessage(state->window, kCompletedMessage, 0, 0);
        }
      }
    }
  }

  void Cancel(const std::string& id, const char* code) {
    const auto found = pending.find(id);
    if (found == pending.end()) return;
    auto request = found->second;
    pending.erase(found);
    request->signal.Cancel();
    {
      std::lock_guard<std::mutex> lock(mutex);
      queued.erase(std::remove(queued.begin(), queued.end(), request), queued.end());
      completed.erase(std::remove(completed.begin(), completed.end(), request), completed.end());
    }
    request->result->Error(code, "System proxy lookup cancelled.");
    request->result.reset();
  }
};

SystemProxyHandler::SystemProxyHandler(flutter::BinaryMessenger* messenger, HWND window)
    : state_(std::make_shared<State>()),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "app.aiplayer/system_proxy", &flutter::StandardMethodCodec::GetInstance())) {
  state_->window = window;
  // Reused bounded workers sleep on a condition variable while idle.
  for (int i = 0; i < 2; ++i) std::thread(State::Worker, state_).detach();
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* id = Argument(call, "id");
    if (call.method_name() == "cancel") {
      if (id) state_->Cancel(*id, "proxy_cancelled");
      result->Success();
    } else if (call.method_name() == "resolve") {
      const auto* url = Argument(call, "url");
      if (!id || id->size() > 128 || !url || url->size() > 16384 || state_->pending.count(*id)) {
        result->Error("proxy_unavailable", "Invalid system proxy request.");
      } else if (state_->pending.size() >= 32) {
        result->Error("proxy_busy", "System proxy lookup queue is full.");
      } else {
        auto request = std::make_shared<Request>();
        if (!request->signal.valid()) {
          result->Error("proxy_unavailable", "Unable to create system proxy request.");
          return;
        }
        request->id = *id;
        request->url = *url;
        request->result = std::move(result);
        state_->pending.emplace(*id, request);
        {
          std::lock_guard<std::mutex> lock(state_->mutex);
          state_->queued.push_back(request);
        }
        state_->changed.notify_one();
      }
    } else {
      result->NotImplemented();
    }
  });
}

SystemProxyHandler::~SystemProxyHandler() {
  channel_->SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->closed = true;
  }
  while (!state_->pending.empty()) state_->Cancel(state_->pending.begin()->first, "proxy_disposed");
  state_->changed.notify_all();
}

void SystemProxyHandler::Complete() {
  std::deque<std::shared_ptr<Request>> completed;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    completed.swap(state_->completed);
  }
  for (const auto& request : completed) {
    if (!request->result) continue;
    state_->pending.erase(request->id);
    if (request->error.empty()) request->result->Success(flutter::EncodableValue(request->route));
    else request->result->Error(request->error, "Unable to resolve the system proxy.");
    request->result.reset();
  }
}
