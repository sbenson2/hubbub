#ifndef PACKAGES_FLUTTER_WEBRTC_LINUX_TASK_RUNNER_LINUX_H_
#define PACKAGES_FLUTTER_WEBRTC_LINUX_TASK_RUNNER_LINUX_H_

#include <atomic>
#include <memory>
#include <mutex>
#include <queue>
#include "task_runner.h"

namespace flutter_webrtc_plugin {

class TaskRunnerLinux : public TaskRunner {
 public:
  TaskRunnerLinux() = default;
  ~TaskRunnerLinux() override = default;

  // TaskRunner implementation.
  void EnqueueTask(TaskClosure task) override;

 private:
  std::mutex tasks_mutex_;
  std::queue<TaskClosure> tasks_;
  // Hubbub patch: set while the tasks are being drained (see the .cc).
  std::atomic<bool> draining_{false};
};

}  // namespace flutter_webrtc_plugin

#endif  // PACKAGES_FLUTTER_WEBRTC_LINUX_TASK_RUNNER_LINUX_H_