/* Build/run from the repository root:
c++ -std=c++14 -Wall -Werror client/linux/host_test/system_proxy_check.cc \
  -Iclient/linux/flutter/ephemeral $(pkg-config --cflags --libs gtk+-3.0) \
  -Lclient/linux/flutter/ephemeral -lflutter_linux_gtk \
  -Wl,-rpath,"$PWD/client/linux/flutter/ephemeral" -o /tmp/aiplayer-proxy-check
/tmp/aiplayer-proxy-check
*/
#include "../runner/system_proxy.cc"

#include <cassert>
#include <atomic>
#include <vector>

namespace {
GThread* main_thread;
GProxyResolver* settings;
GMutex gate_mutex;
GCond gate_changed;
bool blocked = false;
std::atomic<int> started{0};
std::atomic<int> running{0};
std::atomic<int> peak{0};

void Wake(GCancellable*, gpointer) {
  g_mutex_lock(&gate_mutex);
  g_cond_broadcast(&gate_changed);
  g_mutex_unlock(&gate_mutex);
}
}  // namespace

struct TestProxyResolver { GObject parent_instance; };
struct TestProxyResolverClass { GObjectClass parent_class; };
static void test_proxy_resolver_iface_init(GProxyResolverInterface* iface);
G_DEFINE_TYPE_WITH_CODE(TestProxyResolver, test_proxy_resolver, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(G_TYPE_PROXY_RESOLVER, test_proxy_resolver_iface_init))
static void test_proxy_resolver_class_init(TestProxyResolverClass*) {}
static void test_proxy_resolver_init(TestProxyResolver*) {}
static void test_proxy_resolver_iface_init(GProxyResolverInterface* iface) {
  iface->is_supported = [](GProxyResolver*) -> gboolean { return TRUE; };
  iface->lookup = [](GProxyResolver*, const gchar* uri, GCancellable* cancel,
                     GError** error) -> gchar** {
    assert(g_thread_self() != main_thread);
    ++started;
    const int active = ++running;
    int old = peak;
    while (old < active && !peak.compare_exchange_weak(old, active)) {}
    const auto connection = g_cancellable_connect(cancel, G_CALLBACK(Wake), nullptr, nullptr);
    g_mutex_lock(&gate_mutex);
    while (blocked && !g_cancellable_is_cancelled(cancel)) {
      g_cond_wait(&gate_changed, &gate_mutex);
    }
    g_mutex_unlock(&gate_mutex);
    g_cancellable_disconnect(cancel, connection);
    --running;
    if (g_cancellable_set_error_if_cancelled(cancel, error)) return nullptr;
    return g_proxy_resolver_lookup(settings, uri, cancel, error);
  };
}

static void Wait(const std::shared_ptr<State>& state) {
  const gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (state->active != 0) {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    assert(g_get_monotonic_time() < deadline);
    g_usleep(1000);
  }
}

static std::shared_ptr<Request> Lookup(const char* url) {
  auto state = std::make_shared<State>();
  auto request = std::make_shared<Request>();
  request->url = url;
  state->queued.push_back(request);
  Start(state);
  Wait(state);
  return request;
}

int main() {
  main_thread = g_thread_self();
  g_io_extension_point_register(G_PROXY_RESOLVER_EXTENSION_POINT_NAME);
  g_io_extension_point_implement(G_PROXY_RESOLVER_EXTENSION_POINT_NAME,
      test_proxy_resolver_get_type(), "aiplayer-test", 10000);
  g_setenv("GIO_USE_PROXY_RESOLVER", "aiplayer-test", TRUE);
  const char* ignored[] = {"localhost", "*.internal.test", nullptr};
  settings = g_simple_proxy_resolver_new("http://127.0.0.1:7890",
      const_cast<gchar**>(ignored));
  assert(Lookup("https://api.example.test/search?q=episode")->route == "PROXY 127.0.0.1:7890");
  assert(Lookup("http://localhost/file")->route == "DIRECT");
  assert(Lookup("https://media.internal.test/file")->route == "DIRECT");
  g_simple_proxy_resolver_set_default_proxy(G_SIMPLE_PROXY_RESOLVER(settings), "http://[::1]:8080");
  assert(Lookup("https://api.example.test/search")->route == "PROXY [::1]:8080");
  g_simple_proxy_resolver_set_uri_proxy(G_SIMPLE_PROXY_RESOLVER(settings), "http", "http://second.test:3128");
  assert(Lookup("http://api.example.test/search")->route == "PROXY second.test:3128");
  g_simple_proxy_resolver_set_default_proxy(G_SIMPLE_PROXY_RESOLVER(settings), "socks5://localhost:1080");
  assert(Lookup("https://api.example.test/search")->error == "proxy_unsupported");

  // Production scheduling: six requests can start only two native lookups.
  // Cancellation/disposal must release those requests without filling slots
  // from the remaining queue, even with no Flutter frames being rendered.
  blocked = true;
  started = 0;
  peak = 0;
  auto state = std::make_shared<State>();
  std::vector<std::shared_ptr<Request>> requests;
  for (int i = 0; i < 6; ++i) {
    auto request = std::make_shared<Request>();
    request->url = "https://api.example.test/" + std::to_string(i);
    requests.push_back(request);
    state->queued.push_back(request);
  }
  Start(state);
  const gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  while (started < 2) {
    assert(g_get_monotonic_time() < deadline);
    g_usleep(1000);
  }
  assert(state->active == 2 && state->queued.size() == 4 && peak == 2);
  state->closed = true;
  state->queued.clear();
  for (const auto& request : requests) g_cancellable_cancel(request->cancel);
  Wait(state);
  assert(started == 2 && running == 0);
  g_object_unref(settings);
  g_print("Linux system proxy: live settings, bypass, IPv6, unsupported routes, worker bounds and cancellation passed.\n");
}
