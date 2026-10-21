#ifndef RUNNER_OVERLAY_WINDOW_H_
#define RUNNER_OVERLAY_WINDOW_H_

#include <windows.h>

#include <cstdint>
#include <vector>

// The game overlay: a layered popup with per-pixel alpha that is topmost, click-through, never
// activated, has no taskbar or Alt+Tab entry and is hidden from capture (unless the developer
// switch HUBBUB_OVERLAY_CAPTURABLE=1 is set). It is only as big as its image.
class OverlayWindow {
 public:
  // Creates the hidden popup (window class L"HubbubGameOverlay").
  OverlayWindow();
  ~OverlayWindow();

  OverlayWindow(const OverlayWindow&) = delete;
  OverlayWindow& operator=(const OverlayWindow&) = delete;

  // Shows |rgba| (premultiplied RGBA, top-down, physical px) at |width| x |height|, sizing the
  // window to it and keeping its position. False when the image is empty or its length isn't
  // width * height * 4 (or Windows refuses it); the window then keeps its old image.
  bool SetImage(const std::vector<uint8_t>& rgba, int width, int height);

  // Moves the top-left to screen physical px (|x|, |y|), re-asserts topmost without activating,
  // and shows the window if it is hidden.
  void Place(int x, int y);

  void Hide();

  HWND hwnd() const { return hwnd_; }

 private:
  HWND hwnd_ = nullptr;
};

#endif  // RUNNER_OVERLAY_WINDOW_H_
