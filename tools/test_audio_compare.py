"""Unit tests for audio_compare.py with synthetic signals.

    tools/.venv/Scripts/python.exe -m unittest discover -s tools -p "test_audio_compare.py"
"""
import os
import sys
import unittest

import numpy as np
from scipy import signal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audio_compare as ac  # noqa: E402

SR = ac.SR


def speech_like(n_seg=4, seed=1):
    """Voiced bursts (harmonics of 120 Hz with a speech-like tilt, up to 7 kHz) followed by a
    soft fricative (noise above 4 kHz, -20 dB), separated by 500 ms pauses."""
    rng = np.random.default_rng(seed)
    parts = [np.zeros(SR // 2)]
    for k in range(n_seg):
        dur = 0.9 + 0.1 * k
        t = np.arange(int(dur * SR)) / SR
        voiced = sum(np.sin(2 * np.pi * 120 * h * t + h) / h**0.9 for h in range(1, 58))
        env = np.minimum(1, t / 0.03) * np.minimum(1, (dur - t) / 0.03)
        voiced = 0.12 * voiced * env * (1 + 0.3 * np.sin(2 * np.pi * 4 * t))
        sos = signal.butter(4, 4000, "highpass", fs=SR, output="sos")
        fric_n = int(0.18 * SR)
        fric = signal.sosfilt(sos, rng.standard_normal(fric_n)) * 0.02
        fric *= np.minimum(1, np.arange(fric_n) / 200) * np.minimum(1, (fric_n - np.arange(fric_n)) / 200)
        parts += [voiced, fric, np.zeros(SR // 2)]
    return np.concatenate(parts).astype(np.float32)


def segments_of(x):
    env = ac.frame_db(x)
    return ac.find_segments(env, ac.speech_threshold(env))


class Compare(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ref = speech_like()

    def run_pair(self, recv, sent=None):
        sent = self.ref if sent is None else sent
        return ac.analyze(sent, SR, recv, SR)

    def test_identical_copy_is_clean(self):
        r = self.run_pair(self.ref.copy())
        self.assertAlmostEqual(r["delay"]["ms"], 0.0, delta=0.1)
        self.assertEqual(r["muffled"]["verdict"], "no muffling")
        self.assertEqual(r["endings"]["share_truncated"], 0.0)
        self.assertEqual(r["dropouts"]["count"], 0)
        self.assertAlmostEqual(r["level"]["speech_level_diff_db"], 0.0, delta=0.05)
        self.assertEqual(r["segments_found"], 4)

    def test_delay_and_level_are_measured(self):
        d = int(0.2371 * SR)
        recv = np.concatenate([np.zeros(d, np.float32), self.ref * 0.5])
        r = self.run_pair(recv)
        self.assertAlmostEqual(r["delay"]["ms"], 237.1, delta=0.5)
        self.assertAlmostEqual(r["level"]["speech_level_diff_db"], -6.02, delta=0.2)
        self.assertEqual(r["muffled"]["verdict"], "no muffling", r["muffled"])
        self.assertEqual(r["endings"]["share_truncated"], 0.0)

    def test_a_low_passed_copy_is_muffled(self):
        sos = signal.butter(8, 3000, "lowpass", fs=SR, output="sos")
        r = self.run_pair(signal.sosfilt(sos, self.ref).astype(np.float32))
        self.assertEqual(r["muffled"]["verdict"], "MUFFLED", r["muffled"])
        self.assertLess(r["spectrum"]["above_4k_share_change_db"], -6)
        self.assertLess(r["spectrum"]["rolloff95_ratio"], 0.85)
        self.assertLess(r["spectrum"]["centroid_shift_hz"], -100)
        self.assertTrue(r["muffled"]["bandwidth_limited"])

    def test_a_milder_low_pass_is_still_noticed(self):
        sos = signal.butter(8, 5000, "lowpass", fs=SR, output="sos")
        r = self.run_pair(signal.sosfilt(sos, self.ref).astype(np.float32))
        self.assertNotEqual(r["muffled"]["verdict"], "no muffling", r["muffled"])

    def test_an_8k_bandwidth_limit_is_flagged_as_bandwidth_limited(self):
        sos = signal.butter(10, 8000, "lowpass", fs=SR, output="sos")
        r = self.run_pair(signal.sosfilt(sos, self.ref).astype(np.float32))
        self.assertLess(r["spectrum"]["above_8k_share_change_db"], -10)
        self.assertLessEqual(r["muffled"]["cutoff_hz_recv"], 8000)

    def test_a_gated_tail_is_truncated(self):
        recv = self.ref.copy()
        for a, b in segments_of(self.ref):
            end = b * ac.HOP
            recv[end - int(0.2 * SR): end + int(0.3 * SR)] = 0  # cut the last 200 ms
        r = self.run_pair(recv)
        e = r["endings"]
        self.assertEqual(e["share_truncated"], 1.0)
        for s in e["segments"]:
            self.assertAlmostEqual(s["truncated_ms"], 200, delta=40)
        self.assertNotEqual(r["muffled"]["verdict"], "MUFFLED", r["muffled"])  # a cut tail is not a low-pass

    def test_a_cut_fricative_only_is_caught_by_the_hf_tail(self):
        recv = self.ref.copy()
        hp = signal.butter(4, 4000, "highpass", fs=SR, output="sos")
        lp = signal.butter(4, 4000, "lowpass", fs=SR, output="sos")
        for a, b in segments_of(self.ref):
            end = b * ac.HOP
            sl = slice(end - int(0.15 * SR), end)
            recv[sl] = signal.sosfilt(lp, recv[sl])  # HF of the last 150 ms removed
        r = self.run_pair(recv)
        self.assertLess(np.mean([s["tail_hf_change_db"] for s in r["endings"]["segments"]]), -10)

    def test_a_dropout_inside_speech_is_found(self):
        recv = self.ref.copy()
        a, b = segments_of(self.ref)[1]
        mid = (a + b) // 2 * ac.HOP
        recv[mid: mid + int(0.08 * SR)] = 0
        r = self.run_pair(recv)
        self.assertEqual(r["dropouts"]["count"], 1)
        self.assertAlmostEqual(r["dropouts"]["longest_ms"], 80, delta=20)
        self.assertEqual(r["endings"]["share_truncated"], 0.0)

    def test_quiet_noise_does_not_cause_findings(self):
        rng = np.random.default_rng(3)
        recv = self.ref + 0.0005 * rng.standard_normal(len(self.ref)).astype(np.float32)
        r = self.run_pair(recv)
        self.assertEqual(r["muffled"]["verdict"], "no muffling")
        self.assertEqual(r["endings"]["share_truncated"], 0.0)

    def test_clipping_is_counted(self):
        recv = np.clip(self.ref * 20, -1, 1).astype(np.float32)
        r = self.run_pair(recv)
        self.assertGreater(r["level"]["clipping_recv"]["samples_at_full_scale"], 100)
        self.assertEqual(r["level"]["clipping_sent"]["samples_at_full_scale"], 0)

    def test_other_rates_are_resampled(self):
        recv16 = signal.resample_poly(self.ref, 1, 3).astype(np.float32)
        r = ac.analyze(self.ref, SR, recv16, 16000)
        self.assertAlmostEqual(r["delay"]["ms"], 0.0, delta=1.0)
        self.assertLess(r["spectrum"]["above_8k_share_change_db"], -10)

    def test_reports_render(self):
        r = self.run_pair(self.ref.copy())
        md = ac.to_markdown(r, "synthetic")
        self.assertIn("Muffled verdict", md)
        self.assertIn("Segments truncated", md)
        js = ac.to_json(r)
        self.assertNotIn("_internal", js)
        import json

        json.dumps(js)

    def test_silence_in_the_sent_file_is_an_error_not_a_crash(self):
        r = ac.analyze(np.zeros(SR * 2, np.float32), SR, self.ref, SR)
        self.assertIn("error", r)


if __name__ == "__main__":
    unittest.main()
