#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <cstdint>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_channel_;
  bool desktop_ready_ = false;
  bool close_requested_ = false;
  bool video_fullscreen_ = false;
  RECT fullscreen_bounds_{};
  LONG_PTR fullscreen_ex_style_ = 0;
  LONG_PTR fullscreen_style_ = 0;
  WINDOWPLACEMENT fullscreen_placement_{};
  bool floating_ = false;
  RECT saved_bounds_{};
  WINDOWPLACEMENT floating_placement_{};
  bool floating_was_topmost_ = false;

  void SetVideoFullscreen(bool enabled);
  void ExitFloating();

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
