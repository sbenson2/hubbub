#ifndef RUNNER_FOREGROUND_WATCHER_H_
#define RUNNER_FOREGROUND_WATCHER_H_

#include <flutter/encodable_value.h>
#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// Reports the foreground window's facts (see FactsFor) whenever the foreground window changes,
// is minimized or restored, or moves or resizes. Uses out-of-context WinEvent hooks only, so it
// never injects into, hooks or reads another process. Lives on the UI thread, whose message loop
// delivers the hook callbacks; at most one instance is started at a time.
class ForegroundWatcher {
 public:
  // Posts kOverlayFactsMessage to |post_to|, whose handler must call Flush, which passes the
  // facts to |on_facts|.
  ForegroundWatcher(HWND post_to,
                    std::function<void(flutter::EncodableValue)> on_facts);
  ~ForegroundWatcher();  // Stop()

  ForegroundWatcher(const ForegroundWatcher&) = delete;
  ForegroundWatcher& operator=(const ForegroundWatcher&) = delete;

  // Hooks foreground and minimize changes (once), then Schedule(), so the current facts follow.
  void Start();

  // Unhooks everything; a Flush already queued then sends nothing.
  void Stop();

  // Posts one kOverlayFactsMessage unless one is pending, so bursts (a window drag) collapse to
  // the message-loop rate. Does nothing while stopped.
  void Schedule();

  // On kOverlayFactsMessage: re-hooks location changes if the foreground pid changed, then sends
  // the current facts.
  void Flush();

 private:
  static void CALLBACK OnWinEvent(HWINEVENTHOOK hook, DWORD event, HWND hwnd,
                                  LONG id_object, LONG id_child, DWORD thread,
                                  DWORD time);

  // Moves the location hook to |pid| (none for 0 or this process).
  void HookLocation(DWORD pid);

  // The started watcher the hook callback reaches.
  static ForegroundWatcher* active_;

  HWND post_to_;
  std::function<void(flutter::EncodableValue)> on_facts_;
  bool started_ = false;
  bool pending_ = false;
  HWINEVENTHOOK foreground_hook_ = nullptr;
  HWINEVENTHOOK minimize_hook_ = nullptr;
  HWINEVENTHOOK location_hook_ = nullptr;
  DWORD location_pid_ = 0;
  // The foreground window at the last Flush; only its own location changes count.
  HWND tracked_ = nullptr;
};

// The `foreground` contract map for |foreground| (see overlay_host.dart), or EncodableValue()
// (null) when there is no foreground window.
flutter::EncodableValue FactsFor(HWND foreground);

// Every non-empty MatchedExeFullPath under HKCU\System\GameConfigStore\Children\*, in UTF-8.
// Empty when the key is missing.
std::vector<std::string> KnownGamePaths();

#endif  // RUNNER_FOREGROUND_WATCHER_H_
