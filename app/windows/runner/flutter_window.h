#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "foreground_watcher.h"
#include "overlay_window.h"
#include "win32_window.h"

// Sent by `hubbub.exe --quit` to the running instance: do the tray Quit.
constexpr UINT kQuitMessage = WM_APP + 0x51;

// Posted by ForegroundWatcher::Schedule to itself through this window: send the facts now.
constexpr UINT kOverlayFactsMessage = WM_APP + 0x52;

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
  // Handles dev.hubbub/overlay: setImage, place, hide, start, stop and knownGames.
  void HandleOverlayCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // overlay_ if its window exists; null before the first setImage, or when the window failed to
  // create or was destroyed (the next setImage then makes a new one).
  OverlayWindow* LiveOverlay() const;

  bool start_hidden_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Tells Dart about session end and --quit (see PluginAppShell).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> session_channel_;

  // Draws the game overlay for Dart (see overlay_window.h).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> overlay_channel_;

  // Created by the first setImage; until then place and hide do nothing.
  std::unique_ptr<OverlayWindow> overlay_;

  // Sends `foreground` facts to Dart between `start` and `stop`.
  std::unique_ptr<ForegroundWatcher> watcher_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
