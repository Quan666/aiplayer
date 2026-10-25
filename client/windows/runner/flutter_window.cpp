#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <cmath>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>
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
  RECT outer{}, client{};
  GetWindowRect(window, &outer);
  GetClientRect(window, &client);
  // WS_CAPTION remains set for native window behavior, but NCCALCSIZE makes
  // the title area part of Flutter. Measure its actual client size.
  return RECT{0, 0, (outer.right - outer.left) - client.right,
              (outer.bottom - outer.top) - client.bottom};
}

int ResizeBorder(HWND window, int metric) {
  const UINT dpi = FlutterDesktopGetDpiForMonitor(
      MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST));
  using MetricsForDpi = int(WINAPI*)(int, UINT);
  const auto metrics = reinterpret_cast<MetricsForDpi>(
      GetProcAddress(GetModuleHandle(L"user32.dll"), "GetSystemMetricsForDpi"));
  if (metrics) return metrics(metric, dpi) + metrics(SM_CXPADDEDBORDER, dpi);
  return GetSystemMetrics(metric) + GetSystemMetrics(SM_CXPADDEDBORDER);
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
  // The Flutter child covers our custom frame. Let non-client hit tests pass
  // through it so native edge resize and caption drag still reach the parent.
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    ContentSubclassProc, 1, reinterpret_cast<DWORD_PTR>(this));
  const MARGINS margins{1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(GetHandle(), &margins);
  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
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
      last_fullscreen_ = video_fullscreen_;
      last_maximized_ = IsZoomed(GetHandle()) != FALSE;
      window_state_sent_ = true;
      result->Success(WindowState());
    } else if (call.method_name() == "setControlsVisible") {
      const auto* args = call.arguments()
          ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      const auto* value = Argument(args, "visible");
      const auto* visible = value ? std::get_if<bool>(value) : nullptr;
      if (!visible) {
        result->Error("invalid_arguments", "Missing window controls visibility");
        return;
      }
      controls_visible_ = *visible;
      result->Success();
    } else if (call.method_name() == "startDrag") {
      result->Success();
      if (!video_fullscreen_) {
        ReleaseCapture();
        const DWORD position = GetMessagePos();
        PostMessage(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION, position);
      }
    } else if (call.method_name() == "minimize") {
      ShowWindow(GetHandle(), SW_MINIMIZE);
      result->Success();
    } else if (call.method_name() == "toggleMaximize") {
      if (!video_fullscreen_) {
        ShowWindow(GetHandle(), IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
      }
      result->Success();
    } else if (call.method_name() == "requestClose") {
      result->Success();
      // Follow the same saved-progress cleanup as the native close command.
      PostMessage(GetHandle(), WM_CLOSE, 0, 0);
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
    if (flutter_controller_->view()) {
      RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                           ContentSubclassProc, 1);
    }
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
  const MARGINS margins = video_fullscreen_ ? MARGINS{0, 0, 0, 0}
                                          : MARGINS{1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(window, &margins);
  PublishWindowState();
}

void FlutterWindow::ExitFloating() {
  if (!floating_) return;
  floating_ = false;
  SetWindowPlacement(GetHandle(), &floating_placement_);
  SetWindowPos(GetHandle(), floating_was_topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST,
      saved_bounds_.left, saved_bounds_.top, saved_bounds_.right - saved_bounds_.left,
      saved_bounds_.bottom - saved_bounds_.top, SWP_SHOWWINDOW);
}

flutter::EncodableValue FlutterWindow::WindowState() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("fullscreen"), flutter::EncodableValue(video_fullscreen_)},
      {flutter::EncodableValue("maximized"), flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE)}});
}

void FlutterWindow::PublishWindowState() {
  if (!desktop_ready_ || !desktop_channel_) return;
  const bool maximized = IsZoomed(GetHandle()) != FALSE;
  if (window_state_sent_ && last_fullscreen_ == video_fullscreen_ &&
      last_maximized_ == maximized) return;
  window_state_sent_ = true;
  last_fullscreen_ = video_fullscreen_;
  last_maximized_ = maximized;
  desktop_channel_->InvokeMethod("windowStateChanged",
      std::make_unique<flutter::EncodableValue>(WindowState()));
}

LRESULT FlutterWindow::FrameHitTest(LPARAM position) {
  if (video_fullscreen_) return HTCLIENT;
  const HWND window = GetHandle();
  const POINT cursor{GET_X_LPARAM(position), GET_Y_LPARAM(position)};
  RECT bounds{};
  GetWindowRect(window, &bounds);
  if (!PtInRect(&bounds, cursor)) return HTNOWHERE;
  if (!IsZoomed(window)) {
    const int horizontal = ResizeBorder(window, SM_CXSIZEFRAME);
    const int vertical = ResizeBorder(window, SM_CYSIZEFRAME);
    const bool left = cursor.x < bounds.left + horizontal;
    const bool right = cursor.x >= bounds.right - horizontal;
    const bool top = cursor.y < bounds.top + vertical;
    const bool bottom = cursor.y >= bounds.bottom - vertical;
    if (top) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
    if (bottom) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
  }
  // Hidden playback chrome must pass movement and clicks to Flutter so the
  // player can reveal its controls. Resize edges above stay native.
  if (!controls_visible_) return HTCLIENT;
  POINT client = cursor;
  ScreenToClient(window, &client);
  RECT content{};
  GetClientRect(window, &content);
  const double scale = FlutterDesktopGetDpiForMonitor(
      MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST)) / 96.0;
  // Match DesktopWindowFrame: 36 logical pixels high, three 46px controls.
  // Native caption hit testing keeps drag-to-snap, double-click and the system
  // menu working without Dart callbacks on every pointer movement.
  if (client.y >= 0 && client.y < std::lround(36 * scale)) {
    if (client.x < content.right - std::lround(138 * scale)) return HTCAPTION;
    // Keep the maximize button native for Windows 11's hover Snap layouts.
    // Flutter still supplies its appearance and keyboard/semantic action.
    if (client.x >= content.right - std::lround(92 * scale) &&
        client.x < content.right - std::lround(46 * scale)) return HTMAXBUTTON;
  }
  return HTCLIENT;
}

LRESULT CALLBACK FlutterWindow::ContentSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) {
  auto* self = reinterpret_cast<FlutterWindow*>(reference_data);
  if (message == WM_NCHITTEST) {
    const LRESULT hit = self->FrameHitTest(lparam);
    if (hit != HTCLIENT && hit != HTNOWHERE) return HTTRANSPARENT;
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, ContentSubclassProc, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_NCCALCSIZE) {
    auto* rect = wparam ? &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0]
                       : reinterpret_cast<RECT*>(lparam);
    if (!video_fullscreen_ && IsZoomed(hwnd)) {
      // A maximized WS_THICKFRAME window overhangs its work area. Keep Flutter
      // inside it, including taskbars placed on secondary monitors or edges.
      MONITORINFO monitor{sizeof(MONITORINFO)};
      if (GetMonitorInfo(MonitorFromRect(rect, MONITOR_DEFAULTTONEAREST), &monitor)) {
        rect->left = std::max(rect->left, monitor.rcWork.left);
        rect->top = std::max(rect->top, monitor.rcWork.top);
        rect->right = std::min(rect->right, monitor.rcWork.right);
        rect->bottom = std::min(rect->bottom, monitor.rcWork.bottom);
      }
    }
    return 0;
  }
  if (message == WM_NCHITTEST) return FrameHitTest(lparam);
  if (message == WM_ACTIVATE || message == WM_DWMCOMPOSITIONCHANGED) {
    const MARGINS margins = video_fullscreen_ ? MARGINS{0, 0, 0, 0}
                                            : MARGINS{1, 1, 1, 1};
    DwmExtendFrameIntoClientArea(hwnd, &margins);
  }
  if (message == WM_SIZE) PublishWindowState();
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

