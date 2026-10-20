"""Mixes clean speech with deterministic noise at a chosen SNR, for the noisy-speech mode of
app/integration_test/audio_quality_test.dart. The injected file is the noisy one; the comparison
tools/audio_compare.py is made against the clean one, so a tail that the noise suppressor eats
shows up as a truncated ending.

    tools/.venv/Scripts/python.exe tools/make_noisy_speech.py clean.wav noisy.wav [--snr 10] [--seed 1]

Noise (all from one seeded generator, so a run is repeatable bit for bit):
  * pink noise (1/f, FFT shaped), the bulk of the power
  * fan hum: 100 Hz and its harmonics with slow level drift, plus a narrow noise band around 180 Hz
  * keyboard clicks: about 6 per second in bursts, each a 4 to 12 ms decaying burst at 1.5 to 5 kHz
SNR is speech power over noise power, both measured over the active speech frames (10 ms frames
within 35 dB of the 98th percentile). Input: any WAV; output: 16-bit mono at the input rate.
"""
import argparse
import json
import sys

import numpy as np
from scipy import signal
from scipy.io import wavfile

# power shares of the noise, summing to 1
SHARE_PINK, SHARE_HUM, SHARE_CLICKS = 0.65, 0.15, 0.20


def pink(n: int, rng: np.random.Generator) -> np.ndarray:
    spec = rng.standard_normal(n // 2 + 1) + 1j * rng.standard_normal(n // 2 + 1)
    f = np.arange(len(spec), dtype=np.float64)
    f[0] = 1.0
    spec /= np.sqrt(f)
    spec[0] = 0.0
    x = np.fft.irfft(spec, n)
    return x / np.std(x)


def fan_hum(n: int, sr: int, rng: np.random.Generator) -> np.ndarray:
    t = np.arange(n) / sr
    x = np.zeros(n)
    for h, a in ((1, 1.0), (2, 0.6), (3, 0.35), (4, 0.2), (5, 0.1)):
        drift = 1 + 0.2 * np.sin(2 * np.pi * rng.uniform(0.1, 0.4) * t + rng.uniform(0, 6.28))
        x += a * drift * np.sin(2 * np.pi * 100.0 * h * t + rng.uniform(0, 6.28))
    band = signal.sosfilt(signal.butter(2, [150, 210], "bandpass", fs=sr, output="sos"), rng.standard_normal(n))
    x += 0.5 * band / np.std(band) * np.std(x)
    return x / np.std(x)


def clicks(n: int, sr: int, rng: np.random.Generator) -> np.ndarray:
    x = np.zeros(n)
    t = 0.2
    while t < n / sr - 0.05:
        # a burst of 1 to 4 keystrokes 80 to 160 ms apart, then a gap
        for _ in range(int(rng.integers(1, 5))):
            i = int(t * sr)
            dur = int(rng.uniform(0.004, 0.012) * sr)
            if i + dur >= n:
                break
            k = np.arange(dur)
            f0 = rng.uniform(1500, 5000)
            env = np.exp(-k / (dur / 4.0))
            x[i:i + dur] += rng.uniform(0.5, 1.0) * env * np.sin(2 * np.pi * f0 * k / sr + rng.uniform(0, 6.28))
            t += rng.uniform(0.08, 0.16)
        t += rng.exponential(0.12)
    s = np.std(x)
    return x / s if s > 0 else x


def active_mask(x: np.ndarray, sr: int) -> np.ndarray:
    hop = sr // 100
    n = len(x) // hop
    rms = np.sqrt(np.mean(x[: n * hop].reshape(n, hop) ** 2, axis=1))
    db = 20 * np.log10(np.maximum(rms, 1e-9))
    top = np.percentile(db, 98)
    if top < -80.0:  # digital silence
        return np.zeros(n, dtype=bool)
    return db > top - 35.0


def make_noise(n: int, sr: int, seed: int) -> np.ndarray:
    """Unit-power-ish noise (shares applied), deterministic for (n, sr, seed)."""
    rng = np.random.default_rng(seed)
    return (np.sqrt(SHARE_PINK) * pink(n, rng) + np.sqrt(SHARE_HUM) * fan_hum(n, sr, rng)
            + np.sqrt(SHARE_CLICKS) * clicks(n, sr, rng))


def mix(speech: np.ndarray, sr: int, snr_db: float = 10.0, seed: int = 1) -> tuple[np.ndarray, dict]:
    speech = speech.astype(np.float64)
    noise = make_noise(len(speech), sr, seed)
    hop = sr // 100
    m = np.repeat(active_mask(speech, sr), hop)
    m = np.pad(m, (0, len(speech) - len(m)))
    if not m.any():
        raise ValueError("no speech found in the input")
    p_speech = float(np.mean(speech[m] ** 2))
    p_noise = float(np.mean(noise[m] ** 2))
    noise *= np.sqrt(p_speech / (p_noise * 10 ** (snr_db / 10.0)))
    out = speech + noise
    peak = float(np.max(np.abs(out)))
    stats = {"snr_db": snr_db, "seed": seed, "speech_rms": float(np.sqrt(p_speech)),
             "noise_rms": float(np.sqrt(np.mean(noise[m] ** 2))), "peak": peak, "clipped": peak > 32767.0}
    return np.clip(out, -32768, 32767), stats


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clean")
    ap.add_argument("noisy")
    ap.add_argument("--snr", type=float, default=10.0)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(argv)
    sr, x = wavfile.read(a.clean)
    if x.ndim > 1:
        x = x.mean(axis=1)
    if x.dtype == np.int16:
        x = x.astype(np.float64)
    else:  # float WAV: scale to 16-bit units
        x = x.astype(np.float64) * 32768.0
    out, stats = mix(x, sr, a.snr, a.seed)
    wavfile.write(a.noisy, sr, np.round(out).astype(np.int16))
    print(json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
