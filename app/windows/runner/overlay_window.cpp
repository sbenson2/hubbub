#include "overlay_window.h"

namespace {

constexpr wchar_t kOverlayClassName[] = L"HubbubGameOverlay";

// WDA_EXCLUDEFROMCAPTURE, Windows 10 2004 and later.
constexpr DWORD kExcludeFromCapture = 0x00000011;

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;  // clicks fall through to the window below
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_DPICHANGED:
      return 0;  // SetImage alone sets the size
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// The developer switch HUBBUB_OVERLAY_CAPTURABLE=1 keeps the overlay in screenshots.
bool CapturableForDevelopers() {
  wchar_t value[32] = {};
  const DWORD length = GetEnvironmentVariableW(L"HUBBUB_OVERLAY_CAPTURABLE",
                                               value, 32);
  return length > 0 && length < 32 && value[0] == L'1';
}

}  // namespace

OverlayWindow::OverlayWindow() {
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = OverlayWndProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kOverlayClassName;
  // Fails harmlessly with ERROR_CLASS_ALREADY_EXISTS when an earlier overlay registered it.
  RegisterClassExW(&window_class);
  hwnd_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST |
                              WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                          kOverlayClassName, L"", WS_POPUP, 0, 0, 0, 0,
                          nullptr, nullptr, instance, nullptr);
  if (hwnd_ && !CapturableForDevelopers()) {
    // Fails before Windows 10 2004; the overlay then shows in captures too.
    SetWindowDisplayAffinity(hwnd_, kExcludeFromCapture);
  }
}

OverlayWindow::~OverlayWindow() {
  if (hwnd_) DestroyWindow(hwnd_);
}

bool OverlayWindow::SetImage(const std::vector<uint8_t>& rgba, int width,
                             int height) {
  if (!hwnd_ || width <= 0 || height <= 0 ||
      rgba.size() != static_cast<size_t>(width) * height * 4) {
    return false;
  }
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // top-down
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  const HBITMAP bitmap =
      CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!bitmap || !bits) {
    if (bitmap) DeleteObject(bitmap);
    return false;
  }
  // GDI wants BGRA. The pixels are already premultiplied, so only R and B swap.
  auto* out = static_cast<uint8_t*>(bits);
  for (size_t i = 0; i < rgba.size(); i += 4) {
    out[i] = rgba[i + 2];
    out[i + 1] = rgba[i + 1];
    out[i + 2] = rgba[i];
    out[i + 3] = rgba[i + 3];
  }
  const HDC memdc = CreateCompatibleDC(nullptr);
  const HGDIOBJ old = SelectObject(memdc, bitmap);
  SIZE size{width, height};
  POINT zero{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  // A null destination point keeps the window where it is.
  const bool shown = UpdateLayeredWindow(hwnd_, nullptr, nullptr, &size, memdc,
                                         &zero, 0, &blend, ULW_ALPHA) != FALSE;
  SelectObject(memdc, old);
  DeleteDC(memdc);
  DeleteObject(bitmap);
  return shown;
}

void OverlayWindow::Place(int x, int y) {
  if (!hwnd_) return;
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  if (!IsWindowVisible(hwnd_)) ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
}

void OverlayWindow::Hide() {
  if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
}
