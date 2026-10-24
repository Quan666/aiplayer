#include "system_proxy.h"

#include <gio/gio.h>
#include <algorithm>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <string>

namespace system_proxy_linux {
struct Request {
  std::string id;
  std::string url;
  FlMethodCall* call = nullptr;
  GCancellable* cancel = g_cancellable_new();
  std::string route;
  std::string error;
  bool environment_fallback = false;
  ~Request() {
    g_clear_object(&call);
    g_object_unref(cancel);
  }
};

struct State {
  // These fields belong to the platform thread. Workers only use Request.
  std::map<std::string, std::shared_ptr<Request>> pending;
  std::deque<std::shared_ptr<Request>> queued;
  unsigned active = 0;
  bool closed = false;
};

struct Work {
  std::shared_ptr<State> state;
  std::shared_ptr<Request> request;
};

void Start(const std::shared_ptr<State>& state);

void Resolve(GTask* task, gpointer, gpointer task_data, GCancellable* cancel) {
  auto* work = static_cast<Work*>(task_data);
  auto& request = *work->request;
  if (!g_cancellable_is_cancelled(cancel)) {
    // Loading GIO modules, desktop settings and PAC may perform disk/network
    // work. Even resolver initialization belongs on this bounded worker pool.
    GProxyResolver* resolver = g_proxy_resolver_get_default();
    if (g_strcmp0(G_OBJECT_TYPE_NAME(resolver), "GDummyProxyResolver") == 0) {
      // Minimal Linux installations have no desktop proxy backend. Let Dart
      // retain http_proxy/https_proxy/no_proxy instead of overriding them.
      request.environment_fallback = true;
    } else {
      g_autoptr(GError) error = nullptr;
      g_auto(GStrv) proxies = g_proxy_resolver_lookup(
          resolver, request.url.c_str(), cancel, &error);
      if (!proxies || error) {
        request.error = "proxy_resolution_failed";
      } else {
        for (size_t i = 0; proxies[i]; ++i) {
          if (i >= 32) {
            request.error = "proxy_resolution_failed";
            break;
          }
          const char* proxy = proxies[i];
          std::string entry;
          if (g_strcmp0(proxy, "direct://") == 0) {
            entry = "DIRECT";
          } else if (g_str_has_prefix(proxy, "http://") &&
                     !strchr(proxy, '@')) {
            g_autoptr(GSocketConnectable) address =
                g_network_address_parse_uri(proxy, 80, nullptr);
            if (!address) {
              request.error = "proxy_resolution_failed";
              break;
            }
            const char* host = g_network_address_get_hostname(
                G_NETWORK_ADDRESS(address));
            const unsigned port = g_network_address_get_port(
                G_NETWORK_ADDRESS(address));
            const std::string endpoint = strchr(host, ':')
                ? "[" + std::string(host) + "]" : host;
            entry = "PROXY " + endpoint + ":" + std::to_string(port);
          } else {
            request.error = "proxy_unsupported";
            break;
          }
          if (!request.route.empty()) request.route += "; ";
          request.route += entry;
        }
        if (request.route.empty() && request.error.empty()) {
          request.error = "proxy_resolution_failed";
        }
      }
    }
  }
  g_task_return_boolean(task, TRUE);
}

void Complete(GObject*, GAsyncResult* result, gpointer) {
  auto* work = static_cast<Work*>(g_task_get_task_data(G_TASK(result)));
  const auto state = work->state;
  const auto request = work->request;
  --state->active;
  if (!state->closed && request->call) {
    state->pending.erase(request->id);
    if (!request->error.empty()) {
      fl_method_call_respond_error(request->call, request->error.c_str(),
          "Unable to resolve the system proxy.", nullptr, nullptr);
    } else {
      g_autoptr(FlValue) value = request->environment_fallback
          ? nullptr : fl_value_new_string(request->route.c_str());
      fl_method_call_respond_success(request->call, value, nullptr);
    }
    g_clear_object(&request->call);
  }
  Start(state);
}

void Start(const std::shared_ptr<State>& state) {
  while (!state->closed && state->active < 2 && !state->queued.empty()) {
    auto request = state->queued.front();
    state->queued.pop_front();
    ++state->active;
    g_autoptr(GTask) task = g_task_new(nullptr, request->cancel, Complete, nullptr);
    g_task_set_task_data(task, new Work{state, request}, [](gpointer data) {
      delete static_cast<Work*>(data);
    });
    // Some desktop PAC backends cannot interrupt a running lookup. Do not
    // release their concurrency slot until that actual work has finished.
    g_task_set_return_on_cancel(task, FALSE);
    g_task_run_in_thread(task, Resolve);
  }
}

void Cancel(const std::shared_ptr<State>& state, const std::string& id,
            const char* code) {
  const auto found = state->pending.find(id);
  if (found == state->pending.end()) return;
  auto request = found->second;
  state->pending.erase(found);
  state->queued.erase(std::remove(state->queued.begin(), state->queued.end(),
      request), state->queued.end());
  g_cancellable_cancel(request->cancel);
  fl_method_call_respond_error(request->call, code,
      "System proxy lookup cancelled.", nullptr, nullptr);
  g_clear_object(&request->call);
}
}  // namespace system_proxy_linux

using namespace system_proxy_linux;

struct SystemProxyHandler {
  FlMethodChannel* channel;
  std::shared_ptr<State> state = std::make_shared<State>();
};

static void system_proxy_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* handler = static_cast<SystemProxyHandler*>(data);
  auto state = handler->state;
  const char* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  FlValue* id_value = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
      ? fl_value_lookup_string(args, "id") : nullptr;
  const char* id = id_value && fl_value_get_type(id_value) == FL_VALUE_TYPE_STRING
      ? fl_value_get_string(id_value) : nullptr;
  if (g_strcmp0(method, "cancel") == 0) {
    if (id) Cancel(state, id, "proxy_cancelled");
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "resolve") == 0) {
    FlValue* url_value = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
        ? fl_value_lookup_string(args, "url") : nullptr;
    const char* url = url_value && fl_value_get_type(url_value) == FL_VALUE_TYPE_STRING
        ? fl_value_get_string(url_value) : nullptr;
    if (state->closed || !id || strlen(id) > 128 || !url ||
        strlen(url) > 16384 || state->pending.count(id) ||
        (!g_str_has_prefix(url, "http://") && !g_str_has_prefix(url, "https://"))) {
      fl_method_call_respond_error(call, "proxy_unavailable",
          "Invalid system proxy request.", nullptr, nullptr);
    } else if (state->pending.size() >= 32) {
      fl_method_call_respond_error(call, "proxy_busy",
          "System proxy lookup queue is full.", nullptr, nullptr);
    } else {
      auto request = std::make_shared<Request>();
      request->id = id;
      request->url = url;
      request->call = FL_METHOD_CALL(g_object_ref(call));
      state->pending.emplace(id, request);
      state->queued.push_back(request);
      Start(state);
    }
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

SystemProxyHandler* system_proxy_handler_new(FlBinaryMessenger* messenger) {
  auto* handler = new SystemProxyHandler();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  handler->channel = fl_method_channel_new(messenger,
      "app.aiplayer/system_proxy", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(handler->channel, system_proxy_call,
      handler, nullptr);
  return handler;
}

void system_proxy_handler_free(SystemProxyHandler* handler) {
  if (!handler) return;
  handler->state->closed = true;
  fl_method_channel_set_method_call_handler(handler->channel, nullptr, nullptr, nullptr);
  while (!handler->state->pending.empty()) {
    Cancel(handler->state, handler->state->pending.begin()->first, "proxy_disposed");
  }
  g_object_unref(handler->channel);
  delete handler;
}
