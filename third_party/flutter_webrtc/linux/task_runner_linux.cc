#include "task_runner_linux.h"

#include <glib.h>

namespace flutter_webrtc_plugin {

void TaskRunnerLinux::EnqueueTask(TaskClosure task) {
  {
    std::lock_guard<std::mutex> lock(tasks_mutex_);
    tasks_.push(std::move(task));
  }

  GMainContext* context = g_main_context_default();
  if (context) {
    g_main_context_invoke(
        context,
        [](gpointer user_data)  -> gboolean {
          TaskRunnerLinux* runner = static_cast<TaskRunnerLinux*>(user_data);
          // Hubbub patch: run the tasks with the mutex released (a task may
          // enqueue another one; the mutex is not recursive). FIFO kept.
          // g_main_context_invoke runs the callback inline when the caller
          // owns the context, so a task that enqueues would drain the queue
          // recursively and overtake the rest of the batch; the nested call
          // returns instead and the outer loop picks the new task up in order.
          if (runner->draining_.exchange(true)) return G_SOURCE_REMOVE;
          for (;;) {
            std::queue<TaskClosure> batch;
            {
              std::lock_guard<std::mutex> lock(runner->tasks_mutex_);
              if (runner->tasks_.empty()) break;
              batch.swap(runner->tasks_);
            }
            while (!batch.empty()) {
              TaskClosure task = std::move(batch.front());
              batch.pop();
              task();
            }
          }
          runner->draining_ = false;
          return G_SOURCE_REMOVE;
        },
        this);
  }
}

}  // namespace flutter_webrtc_plugin
