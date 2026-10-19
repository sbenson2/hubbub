/* Hubbub test helper (Linux/WSLg): makes a virtual PulseAudio microphone
 * "hubmic" that carries a 1 kHz + 10 kHz tone, so apm_probe can see what the
 * capture post-processor gets for a known signal above 8 kHz. No GUI.
 * Build: gcc pulse_tone.c -o pulse_tone -lpulse -lpulse-simple -lm
 * Run:   PULSE_SERVER=unix:/mnt/wslg/PulseServer ./pulse_tone 40   (seconds) */
#include <math.h>
#include <pulse/pulseaudio.h>
#include <pulse/simple.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int pending = 0;
static uint32_t mods[2];
static void on_done(pa_context* c, int ok, void* u) { (void)c; (void)ok; (void)u; --pending; }
static void on_mod(pa_context* c, const pa_module_info* i, int eol, void* u) {
  if (eol) { --pending; return; }
  if (i->argument && (strstr(i->argument, "hubtest") || strstr(i->argument, "hubmic"))) {
    ++pending;
    pa_operation_unref(pa_context_unload_module(c, i->index, on_done, u));
  }
}
static void on_load(pa_context* c, uint32_t idx, void* u) {
  (void)c; (void)u;
  printf("module loaded: %u\n", idx);
  mods[pending == 2 ? 0 : 1] = idx;
  --pending;
}
static void on_state(pa_context* c, void* u) { (void)c; (void)u; }

int main(int argc, char** argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 30;
  pa_mainloop* ml = pa_mainloop_new();
  pa_context* ctx = pa_context_new(pa_mainloop_get_api(ml), "hubbub-tone");
  pa_context_set_state_callback(ctx, on_state, NULL);
  pa_context_connect(ctx, NULL, PA_CONTEXT_NOFLAGS, NULL);
  while (pa_context_get_state(ctx) != PA_CONTEXT_READY) {
    if (pa_context_get_state(ctx) == PA_CONTEXT_FAILED || pa_context_get_state(ctx) == PA_CONTEXT_TERMINATED) { fprintf(stderr, "connect failed\n"); return 1; }
    pa_mainloop_iterate(ml, 1, NULL);
  }
  /* remove leftovers of an earlier run */
  pending = 1;
  pa_operation_unref(pa_context_get_module_info_list(ctx, on_mod, NULL));
  while (pending) pa_mainloop_iterate(ml, 1, NULL);
  pending = 1;
  pa_context_load_module(ctx, "module-null-sink", "sink_name=hubtest", on_load, NULL);
  while (pending) pa_mainloop_iterate(ml, 1, NULL);
  pending = 1;
  pa_context_load_module(ctx, "module-remap-source", "master=hubtest.monitor source_name=hubmic source_properties=device.description=hubmic", on_load, NULL);
  while (pending) pa_mainloop_iterate(ml, 1, NULL);

  pa_sample_spec ss = {PA_SAMPLE_S16LE, 48000, 1};
  int err = 0;
  pa_simple* s = pa_simple_new(NULL, "hubbub-tone", PA_STREAM_PLAYBACK, "hubtest", "tone", &ss, NULL, NULL, &err);
  if (!s) { fprintf(stderr, "pa_simple_new: %s\n", pa_strerror(err)); return 1; }
  short buf[480];
  long n = 0;
  for (int blk = 0; blk < seconds * 100; ++blk) {
    for (int i = 0; i < 480; ++i, ++n) {
      double t = (double)n / 48000.0;
      buf[i] = (short)(6000 * sin(2 * M_PI * 1000 * t) + 6000 * sin(2 * M_PI * 10000 * t));
    }
    if (pa_simple_write(s, buf, sizeof buf, &err) < 0) { fprintf(stderr, "write: %s\n", pa_strerror(err)); break; }
  }
  pa_simple_drain(s, &err);
  pa_simple_free(s);
  pending = 1;
  pa_operation_unref(pa_context_get_module_info_list(ctx, on_mod, NULL));
  while (pending) pa_mainloop_iterate(ml, 1, NULL);
  return 0;
}
