/*
c++ -std=c++17 -Wall -Werror client/windows/host_test/system_proxy_config_check.cc \
  -o /tmp/aiplayer-windows-proxy-check && /tmp/aiplayer-windows-proxy-check
*/
#include "../runner/system_proxy_config.h"
#include <cassert>
#include <iostream>

int main() {
  using namespace system_proxy_config;
  assert(StaticRoute("", "", "https", "example.test", 443) == "DIRECT");
  assert(StaticRoute("127.0.0.1:7890", "", "https", "example.test", 443) == "PROXY 127.0.0.1:7890");
  assert(StaticRoute("http=first.test:80;https=second.test:443", "", "https", "example.test", 443) == "PROXY second.test:443");
  assert(StaticRoute("http=first.test:80", "", "https", "example.test", 443) == "DIRECT");
  assert(StaticRoute("http://proxy.test", "", "https", "example.test", 443) == "PROXY proxy.test:80");
  assert(StaticRoute("[::1]:7890", "", "https", "example.test", 443) == "PROXY [::1]:7890");
  assert(StaticRoute("proxy.test:3128", "<local>;*.internal.test", "https", "LOCALHOST", 443) == "DIRECT");
  assert(StaticRoute("proxy.test:3128", "<local>;*.internal.test", "https", "MEDIA.internal.test", 443) == "DIRECT");
  assert(StaticRoute("proxy.test:3128", "http://example.test:80", "https", "example.test", 443) == "PROXY proxy.test:3128");
  assert(StaticRoute("proxy.test:3128", "https://example.test:443", "https", "example.test", 443) == "DIRECT");
  assert(StaticRoute("proxy.test:3128", "[::1]", "http", "::1", 80) == "DIRECT");
  assert(StaticRoute("socks=proxy.test:1080", "", "https", "example.test", 443).empty());
  assert(StaticRoute("https://proxy.test:443", "", "https", "example.test", 443).empty());
  assert(StaticRoute("proxy.test:0", "", "https", "example.test", 443).empty());
  assert(StaticRoute("proxy.test:65536", "", "https", "example.test", 443).empty());
  assert(StaticRoute("proxy.test:abc", "", "https", "example.test", 443).empty());
  assert(StaticRoute("[::1]", "", "https", "example.test", 443) == "PROXY [::1]:80");
  assert(StaticRoute("[::1]:80:90", "", "https", "example.test", 443).empty());
  std::cout << "Windows system proxy settings: scheme selection, exclusions, IPv6 and unsupported/malformed routes passed.\n";
}
