#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <cmath>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include <flutter_windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {
constexpr UINT kCloseApplication = WM_APP + 41;

const flutter::EncodableValue* Argument(const flutter::EncodableMap* args,
                                       const char* key) {
  if (!args) return nullptr;
  const auto found = args->find(flutter::EncodableValue(key));
  return found == args->end() ? nullptr : &found->second;
}

double AspectArgument(const flutter::EncodableMap* args, double fallback) {
  const auto* value = Argument(args, "aspectRatio");
  double ratio = fallback;
  if (value) {
    if (const auto* double_value = std::get_if<double>(value)) ratio = *double_value;
    else if (const auto* int32_value = std::get_if<int32_t>(value)) ratio = *int32_value;
    else if (const auto* int64_value = std::get_if<int64_t>(value)) ratio = static_cast<double>(*int64_value);
  }
  return std::isfinite(ratio) && ratio > 0 ? std::clamp(ratio, .01, 100.0) : 16.0 / 9;
}

RECT WindowDecoration(HWND window) {
  RECT decoration{};
  const DWORD style = static_cast<DWORD>(GetWindowLongPtr(window, GWL_STYLE));
  const DWORD extended = static_cast<DWORD>(GetWindowLongPtr(window, GWL_EXSTYLE));
  using AdjustForDpi = BOOL(WINAPI*)(LPRECT, DWORD, BOOL, DWORD, UINT);
  const auto adjust = reinterpret_cast<AdjustForDpi>(
      GetProcAddress(GetModuleHandle(L"user32.dll"), "AdjustWindowRectExForDpi"));
  if (adjust) {
    adjust(&decoration, style, FALSE, extended,
        FlutterDesktopGetDpiForMonitor(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST)));
  } else {
    AdjustWindowRectEx(&decoration, style, FALSE, extended);
  }
  return decoration;
}

std::string HardwareDescription(const wchar_t* name) {
  wchar_t value[256]{};
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DESCRIPTION\\System\\BIOS",
                  name, RRF_RT_REG_SZ, nullptr, value, &size) != ERROR_SUCCESS) {
    return {};
  }
  return Utf8FromUtf16(value);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  system_proxy_ = std::make_unique<SystemProxyHandler>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "app.aiplayer/window_mode",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (call.method_name() == "supported") {
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "setVideoFullscreen") {
      const auto* value = Argument(args, "enabled");
      const auto* enabled = value ? std::get_if<bool>(value) : nullptr;
      ExitFloating();
      SetVideoFullscreen(enabled && *enabled);
      result->Success(flutter::EncodableValue(video_fullscreen_));
    } else if (call.method_name() == "enter") {
      SetVideoFullscreen(false);
      const double ratio = AspectArgument(args, 16.0 / 9);
      if (!floating_) {
        GetWindowRect(GetHandle(), &saved_bounds_);
        floating_placement_.length = sizeof(WINDOWPLACEMENT);
        GetWindowPlacement(GetHandle(), &floating_placement_);
        floating_was_topmost_ = (GetWindowLongPtr(GetHandle(), GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
      }
      floating_ = true;
      ShowWindow(GetHandle(), SW_RESTORE);
      const int height = (std::min)(540, static_cast<int>(480 / ratio));
      const RECT decoration = WindowDecoration(GetHandle());
      SetWindowPos(GetHandle(), HWND_TOPMOST, 0, 0,
          (std::max)(1, static_cast<int>(height * ratio)) + decoration.right - decoration.left,
          (std::max)(1, height) + decoration.bottom - decoration.top,
          SWP_NOMOVE | SWP_SHOWWINDOW);
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "exit") {
      ExitFloating();
      result->Success();
    } else { result->NotImplemented(); }
  });
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "app.aiplayer/desktop_player",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "getDeviceInfo") {
      wchar_t name[MAX_COMPUTERNAME_LENGTH + 1]{};
      DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
      GetComputerNameW(name, &size);
      const std::string computer = Utf8FromUtf16(name);
      const std::string manufacturer = HardwareDescription(L"SystemManufacturer");
      const std::string product = HardwareDescription(L"SystemProductName");
      const std::string model = manufacturer.empty() ? product :
          product.empty() ? manufacturer : manufacturer + " " + product;
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("name"), flutter::EncodableValue(computer)},
          {flutter::EncodableValue("platform"), flutter::EncodableValue("Windows")},
          {flutter::EncodableValue("model"), flutter::EncodableValue(model)}}));
    } else if (call.method_name() == "ready") {
      desktop_ready_ = true;
      result->Success();
    } else if (call.method_name() == "closeWindow") {
      result->Success();
      // Destroy the engine after the method reply has been sent.
      PostMessage(GetHandle(), kCloseApplication, 0, 0);
    } else { result->NotImplemented(); }
  });


  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  system_proxy_.reset();
  window_channel_.reset();
  desktop_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetVideoFullscreen(bool enabled) {
  if (enabled == video_fullscreen_) return;
  HWND window = GetHandle();
  if (enabled) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) return;
    GetWindowRect(window, &fullscreen_bounds_);
    fullscreen_ex_style_ = GetWindowLongPtr(window, GWL_EXSTYLE);
    fullscreen_style_ = GetWindowLongPtr(window, GWL_STYLE);
    fullscreen_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(window, &fullscreen_placement_);
    video_fullscreen_ = true;
    SetWindowLongPtr(window, GWL_STYLE,
        (fullscreen_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
    SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
        monitor.rcMonitor.right - monitor.rcMonitor.left,
        monitor.rcMonitor.bottom - monitor.rcMonitor.top, SWP_SHOWWINDOW | SWP_FRAMECHANGED);
  } else {
    video_fullscreen_ = false;
    SetWindowLongPtr(window, GWL_STYLE, fullscreen_style_);
    SetWindowPlacement(window, &fullscreen_placement_);
    SetWindowPos(window, (fullscreen_ex_style_ & WS_EX_TOPMOST) ? HWND_TOPMOST : HWND_NOTOPMOST,
        fullscreen_bounds_.left, fullscreen_bounds_.top,
        fullscreen_bounds_.right - fullscreen_bounds_.left,
        fullscreen_bounds_.bottom - fullscreen_bounds_.top,
        SWP_SHOWWINDOW | SWP_FRAMECHANGED);
  }
}

void FlutterWindow::ExitFloating() {
  if (!floating_) return;
  floating_ = false;
  SetWindowPlacement(GetHandle(), &floating_placement_);
  SetWindowPos(GetHandle(), floating_was_topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST,
      saved_bounds_.left, saved_bounds_.top, saved_bounds_.right - saved_bounds_.left,
      saved_bounds_.bottom - saved_bounds_.top, SWP_SHOWWINDOW);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == SystemProxyHandler::kCompletedMessage) {
    if (system_proxy_) system_proxy_->Complete();
    return 0;
  }
  // Keep the main engine alive until Dart saves progress and closes playback.
  if (message == WM_CLOSE && desktop_ready_) {
    if (!close_requested_) {
      close_requested_ = true;
      desktop_channel_->InvokeMethod("closeRequested", nullptr);
    }
    return 0;
  } else if (message == kCloseApplication) {
    Destroy();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) return *result;
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

