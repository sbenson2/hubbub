#include "foreground_watcher.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <cstdint>
#include <utility>

#include "flutter_window.h"  // kOverlayFactsMessage
#include "utils.h"

namespace {

flutter::EncodableValue RectValue(const RECT& rect) {
  return flutter::EncodableValue(flutter::EncodableList{
      flutter::EncodableValue(static_cast<int32_t>(rect.left)),
      flutter::EncodableValue(static_cast<int32_t>(rect.top)),
      flutter::EncodableValue(static_cast<int32_t>(rect.right)),
      flutter::EncodableValue(static_cast<int32_t>(rect.bottom)),
  });
}

// The full exe path of |pid|, or '' when it can't be read. Asks only for
// PROCESS_QUERY_LIMITED_INFORMATION (never read or debug rights, which anti-cheat watches for)
// and never retries with more.
std::string ExePath(DWORD pid) {
  const HANDLE process =
      OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return std::string();
  std::string path;
  std::wstring buffer(MAX_PATH, L'\0');
  for (;;) {
    DWORD length = static_cast<DWORD>(buffer.size());
    if (QueryFullProcessImageNameW(process, 0, buffer.data(), &length)) {
      buffer.resize(length);
      path = Utf8FromUtf16(buffer.c_str());
      break;
    }
    // Long paths: grow up to the 32767-character limit.
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || buffer.size() >= 32768) {
      break;
    }
    buffer.resize(buffer.size() * 4);
  }
  CloseHandle(process);
  return path;
}

std::string ClassName(HWND window) {
  wchar_t name[256] = {};  // the longest class name Windows allows
  if (GetClassNameW(window, name, 256) == 0) return std::string();
  return Utf8FromUtf16(name);
}

}  // namespace

ForegroundWatcher* ForegroundWatcher::active_ = nullptr;

ForegroundWatcher::ForegroundWatcher(
    HWND post_to, std::function<void(flutter::EncodableValue)> on_facts)
    : post_to_(post_to), on_facts_(std::move(on_facts)) {}

ForegroundWatcher::~ForegroundWatcher() { Stop(); }

void ForegroundWatcher::Start() {
  if (!started_) {
    started_ = true;
    active_ = this;
    foreground_hook_ = SetWinEventHook(
        EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, OnWinEvent,
        0, 0, WINEVENT_OUTOFCONTEXT);
    minimize_hook_ = SetWinEventHook(EVENT_SYSTEM_MINIMIZESTART,
                                     EVENT_SYSTEM_MINIMIZEEND, nullptr,
                                     OnWinEvent, 0, 0, WINEVENT_OUTOFCONTEXT);
  }
  Schedule();
}

void ForegroundWatcher::Stop() {
  if (!started_) return;
  started_ = false;
  if (active_ == this) active_ = nullptr;
  for (HWINEVENTHOOK* hook :
       {&foreground_hook_, &minimize_hook_, &location_hook_}) {
    if (*hook) UnhookWinEvent(*hook);
    *hook = nullptr;
  }
  location_pid_ = 0;
  tracked_ = nullptr;
}

void ForegroundWatcher::Schedule() {
  if (!started_ || pending_) return;
  // If the post fails (a full queue), the next event tries again.
  pending_ = PostMessageW(post_to_, kOverlayFactsMessage, 0, 0) != FALSE;
}

void ForegroundWatcher::Flush() {
  pending_ = false;
  if (!started_) return;
  const HWND foreground = GetForegroundWindow();
  DWORD pid = 0;
  if (foreground) GetWindowThreadProcessId(foreground, &pid);
  tracked_ = foreground;
  if (pid != location_pid_) HookLocation(pid);
  on_facts_(FactsFor(foreground));
}

void ForegroundWatcher::HookLocation(DWORD pid) {
  if (location_hook_) UnhookWinEvent(location_hook_);
  location_hook_ = nullptr;
  location_pid_ = pid;
  // Process 0 would mean every process, and this process's own windows are never games.
  if (pid == 0 || pid == GetCurrentProcessId()) return;
  location_hook_ = SetWinEventHook(
      EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, nullptr,
      OnWinEvent, pid, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
}

void CALLBACK ForegroundWatcher::OnWinEvent(HWINEVENTHOOK, DWORD event,
                                            HWND hwnd, LONG id_object,
                                            LONG id_child, DWORD, DWORD) {
  ForegroundWatcher* const self = active_;
  if (!self) return;
  // Only the tracked window's own frame counts, not its carets, cursors or child windows.
  if (event == EVENT_OBJECT_LOCATIONCHANGE &&
      (hwnd != self->tracked_ || id_object != OBJID_WINDOW ||
       id_child != CHILDID_SELF)) {
    return;
  }
  self->Schedule();
}

flutter::EncodableValue FactsFor(HWND foreground) {
  if (!foreground) return flutter::EncodableValue();
  DWORD pid = 0;
  GetWindowThreadProcessId(foreground, &pid);

  // The visible frame, without the invisible resize borders GetWindowRect includes.
  RECT window{};
  if (FAILED(DwmGetWindowAttribute(foreground, DWMWA_EXTENDED_FRAME_BOUNDS,
                                   &window, sizeof(window))) &&
      !GetWindowRect(foreground, &window)) {
    window = RECT{};
  }

  RECT client{};
  if (GetClientRect(foreground, &client)) {
    POINT top_left{client.left, client.top};
    POINT bottom_right{client.right, client.bottom};
    ClientToScreen(foreground, &top_left);
    ClientToScreen(foreground, &bottom_right);
    client = RECT{top_left.x, top_left.y, bottom_right.x, bottom_right.y};
  }

  const HMONITOR monitor =
      MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  RECT monitor_rect{};
  if (GetMonitorInfoW(monitor, &info)) monitor_rect = info.rcMonitor;

  const auto style = static_cast<DWORD>(GetWindowLongW(foreground, GWL_STYLE));

  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("hwnd"),
       flutter::EncodableValue(
           static_cast<int64_t>(reinterpret_cast<intptr_t>(foreground)))},
      {flutter::EncodableValue("path"), flutter::EncodableValue(ExePath(pid))},
      {flutter::EncodableValue("own"),
       flutter::EncodableValue(pid == GetCurrentProcessId())},
      {flutter::EncodableValue("cls"),
       flutter::EncodableValue(ClassName(foreground))},
      {flutter::EncodableValue("caption"),
       flutter::EncodableValue((style & WS_CAPTION) == WS_CAPTION)},
      {flutter::EncodableValue("window"), RectValue(window)},
      {flutter::EncodableValue("client"), RectValue(client)},
      {flutter::EncodableValue("monitor"), RectValue(monitor_rect)},
      {flutter::EncodableValue("minimized"),
       flutter::EncodableValue(IsIconic(foreground) != FALSE)},
      {flutter::EncodableValue("dpi"),
       flutter::EncodableValue(
           static_cast<int32_t>(FlutterDesktopGetDpiForMonitor(monitor)))},
  });
}

std::vector<std::string> KnownGamePaths() {
  std::vector<std::string> paths;
  HKEY children = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"System\\GameConfigStore\\Children", 0,
                    KEY_READ, &children) != ERROR_SUCCESS) {
    return paths;
  }
  wchar_t name[256];  // registry key names are at most 255 characters
  for (DWORD index = 0;; ++index) {
    DWORD name_length = 256;
    const LSTATUS status = RegEnumKeyExW(children, index, name, &name_length,
                                         nullptr, nullptr, nullptr, nullptr);
    if (status == ERROR_MORE_DATA) continue;
    if (status != ERROR_SUCCESS) break;  // ERROR_NO_MORE_ITEMS, or a broken key
    DWORD bytes = 0;
    if (RegGetValueW(children, name, L"MatchedExeFullPath", RRF_RT_REG_SZ,
                     nullptr, nullptr, &bytes) != ERROR_SUCCESS ||
        bytes <= sizeof(wchar_t)) {
      continue;  // no value, or an empty one
    }
    std::wstring value(bytes / sizeof(wchar_t), L'\0');
    if (RegGetValueW(children, name, L"MatchedExeFullPath", RRF_RT_REG_SZ,
                     nullptr, value.data(), &bytes) != ERROR_SUCCESS) {
      continue;
    }
    std::string path = Utf8FromUtf16(value.c_str());
    if (!path.empty()) paths.push_back(std::move(path));
  }
  RegCloseKey(children);
  return paths;
}
