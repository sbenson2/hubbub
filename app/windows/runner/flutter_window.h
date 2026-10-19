#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// Sent by `hubbub.exe --quit` to the running instance: do the tray Quit.
constexpr UINT kQuitMessage = WM_APP + 0x51;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Keep the window hidden when the first frame is ready (a start at login). Call before Create.
  void SetStartHidden(bool hidden) { start_hidden_ = hidden; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool start_hidden_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Tells Dart about session end and --quit (see PluginAppShell).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> session_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
