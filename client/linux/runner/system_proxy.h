#ifndef RUNNER_SYSTEM_PROXY_H_
#define RUNNER_SYSTEM_PROXY_H_

#include <flutter_linux/flutter_linux.h>

// Owned by the window, and disposed before its Flutter engine is destroyed.
struct SystemProxyHandler;
SystemProxyHandler* system_proxy_handler_new(FlBinaryMessenger* messenger);
void system_proxy_handler_free(SystemProxyHandler* handler);

#endif
