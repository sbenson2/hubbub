#include "flutter_window.h"

#include <cstdint>
#include <limits>
#include <optional>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The int at |key| in |args|. Dart sends an int as int32 when it fits and as int64 otherwise.
std::optional<int> IntArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    if (*value >= std::numeric_limits<int>::min() &&
        *value <= std::numeric_limits<int>::max()) {
      return static_cast<int>(*value);
    }
  }
  return std::nullopt;
}

// The Uint8List at |key| in |args|, or null.
const std::vector<uint8_t>* BytesArg(const flutter::EncodableMap& args,
                                     const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr
                          : std::get_if<std::vector<uint8_t>>(&it->second);
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
  session_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.hubbub/session",
          &flutter::StandardMethodCodec::GetInstance());
  overlay_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.hubbub/overlay",
          &flutter::StandardMethodCodec::GetInstance());
  overlay_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleOverlayCall(call, std::move(result)); });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->Show();
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
    overlay_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }
  overlay_ = nullptr;

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleOverlayCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (method == "setImage") {
    const auto* rgba = args ? BytesArg(*args, "rgba") : nullptr;
    const auto width = args ? IntArg(*args, "width") : std::nullopt;
    const auto height = args ? IntArg(*args, "height") : std::nullopt;
    if (!rgba || !width || !height) {
      result->Error("bad_args");
      return;
    }
    if (!overlay_) overlay_ = std::make_unique<OverlayWindow>();
    if (!overlay_->SetImage(*rgba, *width, *height)) {
      result->Error("bad_image");
      return;
    }
    result->Success();
  } else if (method == "place") {
    const auto x = args ? IntArg(*args, "x") : std::nullopt;
    const auto y = args ? IntArg(*args, "y") : std::nullopt;
    if (!x || !y) {
      result->Error("bad_args");
      return;
    }
    // Before the first setImage there is nothing to show.
    if (overlay_) overlay_->Place(*x, *y);
    result->Success();
  } else if (method == "hide") {
    if (overlay_) overlay_->Hide();
    result->Success();
  } else {
    result->NotImplemented();
  }
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
