#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <app_links/app_links_plugin_c_api.h>
#include <windows.h>

#include <cwctype>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// HUBBUB_ROOT relocates the data folder so two instances can run side by
// side. It also keys the window title, the single-instance mutex and the
// link hand-off, so instances with different roots never steal each other's
// links. Unset means the default root: plain title, no suffix.
std::wstring DataRoot() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = ::GetEnvironmentVariableW(L"HUBBUB_ROOT", buf, ARRAYSIZE(buf));
  if (n == 0 || n >= ARRAYSIZE(buf)) return L"";
  return std::wstring(buf, n);
}

// The root folder's own name, e.g. "B" for C:\data\B.
std::wstring RootName(std::wstring root) {
  while (!root.empty() && (root.back() == L'\\' || root.back() == L'/')) {
    root.pop_back();
  }
  size_t cut = root.find_last_of(L"\\/");
  return cut == std::wstring::npos ? root : root.substr(cut + 1);
}

std::wstring WindowTitle(const std::wstring& root) {
  if (root.empty()) return L"hubbub";
  return L"hubbub \u2014 " + RootName(root);
}

// Case-insensitive FNV-1a of the root, as a mutex-name-safe suffix.
std::wstring RootKey(const std::wstring& root) {
  unsigned long long h = 1469598103934665603ULL;
  for (wchar_t c : root) {
    h ^= static_cast<unsigned long long>(std::towlower(c));
    h *= 1099511628211ULL;
  }
  wchar_t out[32];
  swprintf_s(out, L"%016llx", h);
  return out;
}

// Registers hubbub:// for the current user on every launch, so the link
// always points at the exe that ran last. Never touches HKLM.
void RegisterUrlScheme() {
  wchar_t exe[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) return;
  const std::wstring command = L"\"" + std::wstring(exe) + L"\" \"%1\"";

  auto set = [](const wchar_t* path, const wchar_t* name,
                const std::wstring& value) {
    HKEY key;
    if (::RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0,
                          KEY_SET_VALUE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS) {
      return;
    }
    ::RegSetValueExW(key, name, 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(value.c_str()),
                     static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    ::RegCloseKey(key);
  };
  set(L"Software\\Classes\\hubbub", nullptr, L"URL:hubbub");
  set(L"Software\\Classes\\hubbub", L"URL Protocol", L"");
  set(L"Software\\Classes\\hubbub\\shell\\open\\command", nullptr, command);
}

struct Find {
  const std::wstring* title;
  wchar_t exe[MAX_PATH];
  HWND found;
};

// Finds a running window of this exe whose title matches exactly. The
// plugin's own SendAppLinkToInstance() matches on exe alone, which would let
// an instance with another root take the link.
HWND FindInstance(const std::wstring& title) {
  Find f = {&title, {}, nullptr};
  ::GetModuleFileNameW(nullptr, f.exe, MAX_PATH);
  ::EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        auto* f = reinterpret_cast<Find*>(lp);
        wchar_t cls[64] = {};
        ::GetClassNameW(hwnd, cls, 64);
        if (_wcsicmp(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
        wchar_t text[256] = {};
        ::GetWindowTextW(hwnd, text, ARRAYSIZE(text));
        if (*f->title != text) return TRUE;
        DWORD pid = 0;
        ::GetWindowThreadProcessId(hwnd, &pid);
        HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!h) return TRUE;
        wchar_t exe[MAX_PATH] = {};
        DWORD len = MAX_PATH;
        ::QueryFullProcessImageNameW(h, 0, exe, &len);
        ::CloseHandle(h);
        if (_wcsicmp(exe, f->exe) != 0) return TRUE;
        f->found = hwnd;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&f));
  return f.found;
}

// Hands this launch's link (if any) to the running instance for the same
// root and brings its window forward. False when there is none.
bool SendToInstance(const std::wstring& title) {
  HWND hwnd = FindInstance(title);
  if (!hwnd || !SendAppLink(hwnd)) return false;
  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd, &place);
  ::ShowWindow(hwnd, place.showCmd == SW_SHOWMAXIMIZED ? SW_SHOWMAXIMIZED
                       : place.showCmd == SW_SHOWMINIMIZED ? SW_RESTORE
                                                           : SW_NORMAL);
  ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  ::SetForegroundWindow(hwnd);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const std::wstring root = DataRoot();
  const std::wstring title = WindowTitle(root);

  RegisterUrlScheme();

  // A window for this root is already up: pass the link on and stop.
  if (SendToInstance(title)) return EXIT_SUCCESS;

  // Two launches at once both miss the window above. The mutex lets only one
  // become the instance; the other waits for its window, then hands over.
  HANDLE mutex =
      ::CreateMutexW(nullptr, TRUE, (L"Local\\hubbub-" + RootKey(root)).c_str());
  if (mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    for (int i = 0; i < 100; ++i) {
      if (SendToInstance(title)) return EXIT_SUCCESS;
      ::Sleep(100);
    }
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
