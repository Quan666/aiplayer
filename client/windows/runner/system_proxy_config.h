#ifndef RUNNER_SYSTEM_PROXY_CONFIG_H_
#define RUNNER_SYSTEM_PROXY_CONFIG_H_

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

// Kept independent of Win32 so static settings and bypass behavior can be
// regression-tested on the host as well as in the Windows runner.
namespace system_proxy_config {
inline std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

inline std::vector<std::string> Tokens(const std::string& value) {
  std::vector<std::string> result;
  size_t start = 0;
  while (start < value.size()) {
    start = value.find_first_not_of("; \t\r\n", start);
    if (start == std::string::npos) break;
    const size_t end = value.find_first_of("; \t\r\n", start);
    result.push_back(value.substr(start, end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return result;
}

inline bool Wildcard(const std::string& pattern, const std::string& value) {
  size_t p = 0, v = 0, star = std::string::npos, retry = 0;
  while (v < value.size()) {
    if (p < pattern.size() && (pattern[p] == '?' || pattern[p] == value[v])) {
      ++p;
      ++v;
    } else if (p < pattern.size() && pattern[p] == '*') {
      star = p++;
      retry = v;
    } else if (star != std::string::npos) {
      p = star + 1;
      v = ++retry;
    } else {
      return false;
    }
  }
  while (p < pattern.size() && pattern[p] == '*') ++p;
  return p == pattern.size();
}

inline bool Bypass(const std::string& list, const std::string& scheme,
                   std::string host, unsigned port) {
  host = Lower(host);
  if (host.find(':') != std::string::npos && host.front() != '[') host = "[" + host + "]";
  const std::string authority = host + ":" + std::to_string(port);
  for (std::string entry : Tokens(Lower(list))) {
    if (entry == "<local>" && host.find_first_of(".:") == std::string::npos) return true;
    const size_t protocol = entry.find("://");
    if (protocol != std::string::npos) {
      if (entry.substr(0, protocol) != scheme) continue;
      entry.erase(0, protocol + 3);
    }
    if (Wildcard(entry, host) || Wildcard(entry, authority)) return true;
  }
  return false;
}

inline std::string Endpoint(std::string value) {
  if (value.compare(0, 7, "http://") == 0) value.erase(0, 7);
  if (value.empty() || value.find_first_of("/\\@?#; \t\r\n") != std::string::npos) return {};
  size_t colon = value.rfind(':');
  if (value.front() == '[') {
    const size_t end = value.find(']');
    if (end == std::string::npos || end == 1) return {};
    if (end + 1 == value.size()) return value + ":80";
    if (value[end + 1] != ':' || colon != end + 1) return {};
  } else if (colon == std::string::npos) {
    return value + ":80";
  } else if (value.find(':') != colon || colon == 0) {
    return {};
  }
  if (colon + 1 == value.size() || value.size() - colon > 6) return {};
  unsigned port = 0;
  for (size_t i = colon + 1; i < value.size(); ++i) {
    if (value[i] < '0' || value[i] > '9') return {};
    port = port * 10 + static_cast<unsigned>(value[i] - '0');
  }
  return port > 0 && port <= 65535 ? value : std::string();
}

// Empty result means an unsupported/malformed configured proxy, never DIRECT.
inline std::string StaticRoute(const std::string& list, const std::string& bypass,
                              const std::string& scheme, const std::string& host,
                              unsigned port) {
  if (Bypass(bypass, scheme, host, port)) return "DIRECT";
  std::vector<std::string> selected;
  bool socks = false;
  for (const auto& token : Tokens(list)) {
    const size_t equals = token.find('=');
    if (equals == std::string::npos) {
      selected.push_back(token);
    } else {
      const auto protocol = Lower(token.substr(0, equals));
      if (protocol == scheme) selected.push_back(token.substr(equals + 1));
      if (protocol == "socks") socks = true;
    }
  }
  if (selected.empty()) return socks ? "" : "DIRECT";
  if (selected.size() > 32) return {};
  std::string route;
  for (const auto& selected_proxy : selected) {
    const auto endpoint = Endpoint(selected_proxy);
    if (endpoint.empty()) return {};
    if (!route.empty()) route += "; ";
    route += "PROXY " + endpoint;
  }
  return route;
}
}  // namespace system_proxy_config
#endif
