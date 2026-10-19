// Real TaskRunnerWindows / TaskRunnerLinux, driven by a message pump / GLib
// main context. Covers the Hubbub fix: tasks run without the queue mutex, so a
// task may enqueue another task (EventChannelProxyImpl::Success -> PostEvent
// does exactly that from the levels/layout publish tasks). Before the fix the
// nested EnqueueTask self-deadlocked; a watchdog turns the hang into a FAIL.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "task_runner.h"
#ifdef _WIN32
#include "task_runner_windows.h"
using Runner = flutter_webrtc_plugin::TaskRunnerWindows;
#else
#include <glib.h>
#include "task_runner_linux.h"
using Runner = flutter_webrtc_plugin::TaskRunnerLinux;
#endif

static int g_failures = 0;
static std::atomic<bool> g_progress{false};
static const char* g_case = "";

#define CHECK(cond)                                                     \
  do {                                                                  \
    if (!(cond)) {                                                      \
      std::printf("FAIL %s: %s (line %d)\n", g_case, #cond, __LINE__);  \
      ++g_failures;                                                     \
    }                                                                   \
  } while (0)

// One watchdog for the whole run: if a case makes no progress for 5 s the
// process is deadlocked; report and exit non-zero instead of hanging.
static void StartWatchdog() {
  std::thread([] {
    for (;;) {
      g_progress = false;
      for (int i = 0; i < 50; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (g_progress) break;
      }
      if (!g_progress) {
        std::printf("FAIL %s: HANG (no progress for 5 s, platform thread "
                    "deadlocked)\n", g_case);
        std::fflush(stdout);
        std::_Exit(2);
      }
    }
  }).detach();
}

// Pump the platform thread until done() or the timeout.
static void Pump(const std::function<bool()>& done, int ms = 3000) {
  auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (!done() && std::chrono::steady_clock::now() < end) {
    g_progress = true;
#ifdef _WIN32
    MSG msg;
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
#else
    g_main_context_iteration(nullptr, FALSE);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
#endif
  }
}

// The shape of EventChannelProxyImpl::Success -> PostEvent once Dart listens:
// delivery is a task enqueued on the same runner.
struct ProxyLike {
  TaskRunner* runner;
  std::vector<int>* delivered;
  void Success(int event) {
    runner->EnqueueTask([this, event] { delivered->push_back(event); });
  }
};

static void TestNestedEnqueue(Runner& r) {
  g_case = "nested enqueue";
  std::vector<std::string> order;
  // A seed task queues A and D; A queues C from inside a task. (The seed
  // makes the queue state the same on Linux, where a plain EnqueueTask from the
  // owning thread runs inline.)
  r.EnqueueTask([&] {
    r.EnqueueTask([&] {
      order.push_back("a");
      r.EnqueueTask([&] { order.push_back("c"); });  // from inside a task
      order.push_back("b");
    });
    r.EnqueueTask([&] { order.push_back("d"); });
  });
  Pump([&] { return order.size() >= 4; });
  std::string s;
  for (auto& x : order) s += x;
  // Strict FIFO: the nested task goes behind the one already queued.
  CHECK(order.size() == 4);
  CHECK(s == "abdc");
}

static void TestFifoOrder(Runner& r) {
  g_case = "FIFO order";
  std::vector<int> got;
  for (int i = 0; i < 100; ++i) r.EnqueueTask([&got, i] { got.push_back(i); });
  Pump([&] { return got.size() >= 100; });
  CHECK(got.size() == 100);
  bool ordered = true;
  for (size_t i = 0; i < got.size(); ++i) ordered &= (got[i] == (int)i);
  CHECK(ordered);
}

// The publisher thread pattern: a thread enqueues tasks that call
// proxy.Success (which enqueues the delivery task). Every event is delivered
// exactly once, in order.
static void TestPublisherThroughProxy(Runner& r) {
  g_case = "publisher via proxy";
  std::vector<int> delivered;
  ProxyLike proxy{&r, &delivered};
  const int kEvents = 200;
  std::thread publisher([&] {
    for (int i = 0; i < kEvents; ++i) {
      r.EnqueueTask([&proxy, i] { proxy.Success(i); });
      if (i % 20 == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  });
  Pump([&] { return delivered.size() >= (size_t)kEvents; });
  publisher.join();
  Pump([] { return false; }, 200);  // grace: a duplicate delivery would show
  CHECK(delivered.size() == (size_t)kEvents);  // once each, none lost
  bool ordered = true;
  for (size_t i = 0; i < delivered.size(); ++i) ordered &= (delivered[i] == (int)i);
  CHECK(ordered);
}

#ifndef _WIN32
// A task that throws must not leave the runner "draining" for ever: the next
// task still runs. (The test owns the main context, so the throw comes back
// out of EnqueueTask.)
static void TestThrowingTask(Runner& r) {
  g_case = "throwing task";
  bool ran = false;
  try {
    r.EnqueueTask([] { throw std::runtime_error("boom"); });
  } catch (const std::exception&) {
  }
  r.EnqueueTask([&] { ran = true; });
  Pump([&] { return ran; });
  CHECK(ran);
}
#endif

int main() {
  StartWatchdog();
  {
    Runner r;
    TestNestedEnqueue(r);
    TestFifoOrder(r);
  }
#ifndef _WIN32
  {
    Runner r;
    TestThrowingTask(r);
  }
#endif
  {
    Runner r;
    TestPublisherThroughProxy(r);
  }
  if (g_failures) {
    std::printf("FAILED (%d)\n", g_failures);
    return 1;
  }
  std::printf("ALL PASSED\n");
  return 0;
}
