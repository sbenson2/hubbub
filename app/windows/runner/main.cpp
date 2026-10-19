#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <app_links/app_links_plugin_c_api.h>
#include <windows.h>

#include <cwctype>
#include <string>

#include <shellapi.h>

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

// Case-insensitive FNV-1a of the root with trailing separators trimmed. The
// one key behind both the mutex name and the window property the finder
// compares (a number, since a property value must make sense to another
// process), so "C:\\x\\hub" and "D:\\y\\hub" stay distinct although their
// titles match.
unsigned long long RootKey(std::wstring root) {
  while (!root.empty() && (root.back() == L'\\' || root.back() == L'/')) {
    root.pop_back();
  }
  unsigned long long h = 1469598103934665603ULL;
  for (wchar_t c : root) {
    h ^= static_cast<unsigned long long>(std::towlower(c));
    h *= 1099511628211ULL;
  }
  return h | 1;  // never 0, so an unset property cannot match
}

// The installer glue lives in hubbub_app.dll (app/rust/src/install.rs), next to the Velopack
// crate whose hooks it answers. It is loaded here, before Flutter starts, because Velopack runs a
// hook by launching this exe with --veloapp-* and expects it to act and exit within seconds.
// Missing library or symbol (a stripped dev bundle) means no installer glue, never a failed start.
void CallInstallerGlue(const char* symbol) {
  HMODULE lib = ::LoadLibraryW(L"hubbub_app.dll");
  if (!lib) return;
  auto fn = reinterpret_cast<void (*)()>(::GetProcAddress(lib, symbol));
  if (fn) fn();
}

// True when the command line carries `flag`.
bool HasArg(const wchar_t* flag) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  bool found = false;
  for (int i = 1; argv && i < argc; ++i) {
    if (_wcsicmp(argv[i], flag) == 0) found = true;
  }
  if (argv) ::LocalFree(argv);
  return found;
}

// Window property holding the owner's RootKey, set once its window exists.
const wchar_t kRootProp[] = L"hubbub.root";

struct Find {
  unsigned long long key;
  wchar_t exe[MAX_PATH];
  HWND found;
};

// Finds a running window of this exe tagged with this root's key. The
// plugin's own SendAppLinkToInstance() matches on exe alone, which would let
// an instance with another root take the link.
HWND FindInstance(unsigned long long key) {
  Find f = {key, {}, nullptr};
  ::GetModuleFileNameW(nullptr, f.exe, MAX_PATH);
  ::EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        auto* f = reinterpret_cast<Find*>(lp);
        wchar_t cls[64] = {};
        ::GetClassNameW(hwnd, cls, 64);
        if (_wcsicmp(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
        // The title only carries the folder's name; the property carries
        // the full root. A window without it is still starting up.
        auto tag = reinterpret_cast<unsigned long long>(
            ::GetPropW(hwnd, kRootProp));
        if (tag != f->key) return TRUE;
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
bool SendToInstance(unsigned long long key) {
  HWND hwnd = FindInstance(key);
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

// `hubbub.exe --quit`: ask the running instance for this root to do the tray Quit (clean
// shutdown, then exit) and wait for it to be gone. Nothing is shown. Succeeds either way.
void QuitInstance(unsigned long long key) {
  HWND hwnd = FindInstance(key);
  if (!hwnd) return;
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  HANDLE h = ::OpenProcess(SYNCHRONIZE, FALSE, pid);
  ::PostMessageW(hwnd, kQuitMessage, 0, 0);
  if (h) {
    ::WaitForSingleObject(h, 20000);
    ::CloseHandle(h);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // First thing: a Velopack hook (install, update, uninstall) runs here and exits the process;
  // an ordinary launch registers hubbub:// for the path it runs from (never touching HKLM).
  CallInstallerGlue("hubbub_startup");

  const std::wstring root = DataRoot();
  const std::wstring title = WindowTitle(root);
  const unsigned long long key = RootKey(root);

  if (HasArg(L"--quit")) {
    QuitInstance(key);
    return EXIT_SUCCESS;
  }

  // A window for this root is already up: pass the link on and stop.
  if (SendToInstance(key)) return EXIT_SUCCESS;

  // Two launches at once both miss the window above. The mutex lets only one
  // become the instance; the other waits for its window, then hands over.
  wchar_t mutex_name[48];
  swprintf_s(mutex_name, L"Local\\hubbub-%016llx", key);
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, mutex_name);
  if (mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    for (int i = 0; i < 100; ++i) {
      if (SendToInstance(key)) return EXIT_SUCCESS;
      ::Sleep(100);
    }
    return EXIT_FAILURE;
  }

  // The one running instance applies an update that was downloaded but never installed (the
  // last session ended without a clean quit); this relaunches the new version and exits.
  CallInstallerGlue("hubbub_apply_pending");

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
  // A start at login (the Run entry passes --background) sits in the tray; Dart shows the
  // window if there turns out to be no tray.
  window.SetStartHidden(HasArg(L"--background"));
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(title, origin, size)) {
    return EXIT_FAILURE;
  }
  // Tag the window with the full root so a second launch finds this one and
  // no other, whatever the titles say.
  ::SetPropW(window.GetHandle(), kRootProp,
             reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(key)));
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
