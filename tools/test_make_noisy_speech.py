"""Tests for make_noisy_speech.py.

    tools/.venv/Scripts/python.exe -m unittest discover -s tools -p "test_make_noisy_speech.py"
"""
import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_noisy_speech as mn  # noqa: E402

SR = 48000


def speech(seed=0):
    rng = np.random.default_rng(seed)
    t = np.arange(SR * 4) / SR
    env = (np.sin(2 * np.pi * 0.7 * t) > 0).astype(float)
    return 6000 * env * np.sin(2 * np.pi * 150 * t) * (1 + 0.1 * rng.standard_normal(len(t)))


class NoisySpeech(unittest.TestCase):
    def test_deterministic(self):
        a, _ = mn.mix(speech(), SR, 10, seed=3)
        b, _ = mn.mix(speech(), SR, 10, seed=3)
        c, _ = mn.mix(speech(), SR, 10, seed=4)
        self.assertTrue(np.array_equal(a, b))
        self.assertFalse(np.array_equal(a, c))

    def test_snr_is_as_asked(self):
        s = speech()
        out, st = mn.mix(s, SR, 10, seed=1)
        m = np.repeat(mn.active_mask(s, SR), SR // 100)
        m = np.pad(m, (0, len(s) - len(m)))
        snr = 10 * np.log10(np.mean(s[m] ** 2) / np.mean((out - s)[m] ** 2))
        self.assertAlmostEqual(snr, 10, delta=0.2)
        self.assertEqual(len(out), len(s))

    def test_noise_has_pink_hum_and_clicks(self):
        n = mn.make_noise(SR * 5, SR, 1)
        f = np.fft.rfftfreq(len(n), 1 / SR)
        p = np.abs(np.fft.rfft(n)) ** 2
        low = p[(f > 200) & (f < 400)].mean()
        high = p[(f > 4000) & (f < 6000)].mean()
        self.assertGreater(low, 5 * high)  # tilted down, not white
        hum = p[(f > 98) & (f < 102)].mean()
        near = p[(f > 60) & (f < 90)].mean()
        self.assertGreater(hum, 5 * near)  # the 100 Hz line stands out
        c = mn.clicks(SR * 5, SR, np.random.default_rng(1))
        self.assertGreater(np.max(np.abs(c)) / np.std(c), 6)  # impulsive

    def test_silence_is_refused(self):
        with self.assertRaises(ValueError):
            mn.mix(np.zeros(SR), SR)


if __name__ == "__main__":
    unittest.main()
