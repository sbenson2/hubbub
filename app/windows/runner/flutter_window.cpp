#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
  session_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.hubbub/session",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (flutter_controller_) {
    session_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Windows logoff or shutdown sends WM_ENDSESSION, not WM_CLOSE, and the window may sit hidden
  // for days, so this is how the app usually ends. Give Dart a few seconds to shut the hub down
  // (Resign, stop livekit-server); the OS kills the process soon after we return.
  if (message == WM_ENDSESSION && wparam && session_channel_) {
    bool done = false;
    session_channel_->InvokeMethod(
        "sessionEnd", nullptr,
        std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [&done](const flutter::EncodableValue*) { done = true; },
            [&done](const std::string&, const std::string&,
                    const flutter::EncodableValue*) { done = true; },
            [&done]() { done = true; }));
    const ULONGLONG deadline = ::GetTickCount64() + 4000;
    ::MSG msg;
    while (!done && ::GetTickCount64() < deadline) {
      if (::PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      } else {
        ::MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
      }
    }
    return 0;
  }
  if (message == kQuitMessage && session_channel_) {
    session_channel_->InvokeMethod("quit", nullptr);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
