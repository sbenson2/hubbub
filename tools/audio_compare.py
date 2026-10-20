#!/usr/bin/env python3
"""Compare a sent and a received recording of the same speech.

Built to answer "my voice sounds muffled and cuts off a bit at the end of what I say":
it aligns the two files by cross-correlation and reports

  * delay, level difference and clipping,
  * "muffled" metrics: long-term spectrum difference in third-octave bands, the share of
    energy above 4 kHz and above 8 kHz, the effective bandwidth (95 % energy roll-off) and
    the spectral centroid shift,
  * "cut-off endings": for every speech segment, where the received speech stops compared
    with where the sent speech stops (within the 300 ms around the sent offset), the truncated
    tail in ms and the share of segments truncated,
  * dropouts and gaps in the received speech,
  * PESQ (wide band) and STOI when `pesq` / `pystoi` are installed.

It writes a Markdown table, a JSON file and (with matplotlib) a spectrogram comparison PNG.

    python tools/audio_compare.py --sent send-processed.wav --received recv-bob.wav --out-dir out

Needs numpy and scipy; optional: matplotlib, pesq, pystoi (see tools/README-audio.md, or just
`python -m venv tools/.venv && tools/.venv/bin/pip install numpy scipy matplotlib pesq pystoi`;
the venv is git-ignored). Everything is measured on 48 kHz mono audio.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 48000
HOP_MS = 10
HOP = SR * HOP_MS // 1000  # 480 samples per envelope frame
EPS = 1e-12

# Verdict thresholds (see `muffled_verdict`).
HF4K_DROP_DB = -3.0        # share of energy above 4 kHz fell by this much
HF8K_DROP_DB = -6.0        # share of energy above 8 kHz fell by this much
ROLLOFF_RATIO = 0.85       # 95 % roll-off fell to this fraction
CENTROID_SHIFT_HZ = -250.0
TRUNCATED_MS = 40          # a tail shorter than this by the receiver counts as truncated
TAIL_LOSS_DB = -10.0       # or the last 100 ms lost this much more than the body of the segment


# ----------------------------------------------------------------------------------------------
# I/O
# ----------------------------------------------------------------------------------------------
def read_wav(path: str) -> tuple[np.ndarray, int]:
    """Mono float32 in -1..1 and the sample rate."""
    sr, x = wavfile.read(path)
    if x.dtype == np.int16:
        x = x.astype(np.float32) / 32768.0
    elif x.dtype == np.int32:
        x = x.astype(np.float32) / 2147483648.0
    elif x.dtype == np.uint8:
        x = (x.astype(np.float32) - 128.0) / 128.0
    else:
        x = x.astype(np.float32)
    if x.ndim > 1:
        x = x.mean(axis=1)
    return x, int(sr)


def to_rate(x: np.ndarray, sr: int, target: int = SR) -> np.ndarray:
    if sr == target:
        return x
    g = math.gcd(sr, target)
    return signal.resample_poly(x, target // g, sr // g).astype(np.float32)


def db(v: float) -> float:
    return float(20.0 * math.log10(max(float(v), 1e-9)))


def db_pow(v: float) -> float:
    return float(10.0 * math.log10(max(float(v), 1e-18)))


# ----------------------------------------------------------------------------------------------
# Alignment
# ----------------------------------------------------------------------------------------------
def estimate_delay(sent: np.ndarray, recv: np.ndarray, max_lag_s: float = 10.0) -> tuple[int, float, bool]:
    """Samples the received signal lags the sent one by (negative: leads), the normalised
    correlation peak, and whether the polarity is inverted."""
    n = len(sent) + len(recv) - 1
    nfft = 1 << (n - 1).bit_length()
    s = np.fft.rfft(sent, nfft)
    r = np.fft.rfft(recv, nfft)
    c = np.fft.irfft(r * np.conj(s), nfft)
    # c[k] is lag k for k >= 0; lag -q is c[nfft - q].
    max_lag = int(max_lag_s * SR)
    p_max = min(max_lag, len(recv) - 1)
    q_max = min(max_lag, len(sent) - 1)
    cand = np.concatenate([c[nfft - q_max:], c[: p_max + 1]]) if q_max > 0 else c[: p_max + 1]
    lags = np.arange(-q_max, p_max + 1)
    i = int(np.argmax(np.abs(cand)))
    peak = float(cand[i])
    norm = math.sqrt(float(np.sum(sent.astype(np.float64) ** 2)) * float(np.sum(recv.astype(np.float64) ** 2))) + EPS
    return int(lags[i]), abs(peak) / norm, peak < 0


def align(sent: np.ndarray, recv: np.ndarray, lag: int) -> tuple[np.ndarray, np.ndarray]:
    if lag > 0:
        recv = recv[lag:]
    elif lag < 0:
        sent = sent[-lag:]
    n = min(len(sent), len(recv))
    return sent[:n], recv[:n]


# ----------------------------------------------------------------------------------------------
# Envelope and segments
# ----------------------------------------------------------------------------------------------
def frame_db(x: np.ndarray) -> np.ndarray:
    n = len(x) // HOP
    f = x[: n * HOP].astype(np.float64).reshape(n, HOP)
    rms = np.sqrt(np.mean(f * f, axis=1))
    return 20.0 * np.log10(np.maximum(rms, 1e-9))


def band_frame_db(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    sos = signal.butter(4, [lo, min(hi, SR / 2 - 100)], btype="bandpass", fs=SR, output="sos")
    return frame_db(signal.sosfilt(sos, x))


def speech_threshold(env: np.ndarray) -> float:
    e = np.maximum(env, -90.0)
    peak = float(np.percentile(e, 98))
    floor = float(np.percentile(e, 10))
    return max(peak - 40.0, floor + 10.0, -75.0)


def find_segments(env: np.ndarray, thr: float, hang_ms: int = 150, min_ms: int = 120) -> list[tuple[int, int]]:
    """Runs of frames above `thr` (gaps shorter than `hang_ms` merged, runs shorter than
    `min_ms` dropped), as [start, end) frame indices."""
    active = env > thr
    runs: list[list[int]] = []
    i = 0
    n = len(active)
    while i < n:
        if active[i]:
            j = i
            while j < n and active[j]:
                j += 1
            runs.append([i, j])
            i = j
        else:
            i += 1
    merged: list[list[int]] = []
    hang = hang_ms // HOP_MS
    for r in runs:
        if merged and r[0] - merged[-1][1] <= hang:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return [(a, b) for a, b in merged if (b - a) * HOP_MS >= min_ms]


# ----------------------------------------------------------------------------------------------
# Spectrum
# ----------------------------------------------------------------------------------------------
THIRD_OCT = [1000.0 * 2 ** (k / 3.0) for k in range(-10, 14)]  # 100 Hz .. 16 kHz


def active_samples(x: np.ndarray, segs: list[tuple[int, int]]) -> np.ndarray:
    if not segs:
        return x
    return np.concatenate([x[a * HOP : b * HOP] for a, b in segs])


def long_term_psd(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    nper = min(4096, max(256, len(x) // 4))
    f, p = signal.welch(x, fs=SR, window="hann", nperseg=nper, noverlap=nper // 2, scaling="spectrum")
    return f, p


def third_octave_levels(f: np.ndarray, p: np.ndarray) -> list[float]:
    out = []
    for fc in THIRD_OCT:
        lo, hi = fc / 2 ** (1 / 6), fc * 2 ** (1 / 6)
        if hi > SR / 2:
            out.append(float("nan"))
            continue
        m = (f >= lo) & (f < hi)
        out.append(db_pow(float(np.sum(p[m]))) if m.any() else float("nan"))
    return out


def spectral_summary(f: np.ndarray, p: np.ndarray) -> dict:
    total = float(np.sum(p)) + EPS
    cum = np.cumsum(p) / total
    roll95 = float(f[int(np.searchsorted(cum, 0.95))])
    return {
        "centroid_hz": float(np.sum(f * p) / total),
        "rolloff95_hz": roll95,
        "share_above_4k": float(np.sum(p[f >= 4000]) / total),
        "share_above_8k": float(np.sum(p[f >= 8000]) / total),
        "power_above_4k_db": db_pow(float(np.sum(p[f >= 4000]))),
        "power_above_8k_db": db_pow(float(np.sum(p[f >= 8000]))),
    }


def cutoff_hz(levels: list[float], below_peak_db: float = 45.0) -> float:
    """Highest third-octave band centre within `below_peak_db` of the strongest band."""
    v = np.array(levels, dtype=np.float64)
    ok = ~np.isnan(v)
    if not ok.any():
        return 0.0
    top = np.nanmax(v)
    best = 0.0
    for fc, lv, good in zip(THIRD_OCT, v, ok):
        if good and lv >= top - below_peak_db:
            best = fc
    return best


# ----------------------------------------------------------------------------------------------
# Main analysis
# ----------------------------------------------------------------------------------------------
def analyze(sent_in: np.ndarray, sr_sent: int, recv_in: np.ndarray, sr_recv: int, max_lag_s: float = 10.0) -> dict:
    sent0 = to_rate(sent_in, sr_sent)
    recv0 = to_rate(recv_in, sr_recv)
    r: dict = {"inputs": {"sent_rate": sr_sent, "recv_rate": sr_recv, "sent_s": len(sent0) / SR, "recv_s": len(recv0) / SR}}
    if len(sent0) < SR // 2 or len(recv0) < SR // 2:
        r["error"] = "a file is shorter than 0.5 s"
        return r

    lag, corr, inverted = estimate_delay(sent0, recv0, max_lag_s)
    sent, recv = align(sent0, recv0, lag)
    r["delay"] = {"ms": 1000.0 * lag / SR, "correlation": corr, "polarity_inverted": inverted,
                  "compared_s": len(sent) / SR,
                  "unmatched_start_s": abs(lag) / SR,
                  "note": "positive: the received audio is later than the sent audio"}
    if inverted:
        recv = -recv
    if len(sent) < SR // 2:
        r["error"] = "aligned overlap shorter than 0.5 s"
        return r

    # ---- levels, clipping
    env_s, env_r = frame_db(sent), frame_db(recv)
    thr = speech_threshold(env_s)
    segs = find_segments(env_s, thr)
    mask = np.zeros(len(env_s), dtype=bool)
    for a, b in segs:
        mask[a:b] = True
    act_s, act_r = active_samples(sent, segs), active_samples(recv, segs)
    rms_s = float(np.sqrt(np.mean(act_s.astype(np.float64) ** 2))) if len(act_s) else 0.0
    rms_r = float(np.sqrt(np.mean(act_r.astype(np.float64) ** 2))) if len(act_r) else 0.0

    def clip_stats(x: np.ndarray) -> dict:
        hit = np.abs(x) >= 0.999
        return {"samples_at_full_scale": int(hit.sum()), "share": float(hit.mean()),
                "peak_dbfs": db(float(np.max(np.abs(x))) if len(x) else 0.0)}

    r["level"] = {
        "speech_rms_dbfs_sent": db(rms_s), "speech_rms_dbfs_recv": db(rms_r),
        "speech_level_diff_db": db(rms_r) - db(rms_s),
        "overall_rms_diff_db": db(float(np.sqrt(np.mean(recv.astype(np.float64) ** 2)))) - db(float(np.sqrt(np.mean(sent.astype(np.float64) ** 2)))),
        "peak_diff_db": db(float(np.max(np.abs(recv)))) - db(float(np.max(np.abs(sent)))),
        "noise_floor_dbfs_sent": float(np.percentile(np.maximum(env_s, -90), 10)),
        "noise_floor_dbfs_recv": float(np.percentile(np.maximum(env_r, -90), 10)),
        "clipping_sent": clip_stats(sent), "clipping_recv": clip_stats(recv),
    }
    r["segments_found"] = len(segs)
    r["speech_threshold_dbfs"] = thr
    if not segs:
        r["error"] = "no speech found in the sent file"
        return r

    # ---- spectrum ("muffled")
    fs_, ps = long_term_psd(act_s)
    fr_, pr = long_term_psd(act_r)
    bs, br = third_octave_levels(fs_, ps), third_octave_levels(fr_, pr)
    ss, sr_ = spectral_summary(fs_, ps), spectral_summary(fr_, pr)
    level_off = r["level"]["speech_level_diff_db"]
    ref_idx = [i for i, fc in enumerate(THIRD_OCT) if 500 <= fc <= 2000]
    ref_diff = float(np.nanmean([br[i] - bs[i] for i in ref_idx]))
    bands = []
    for fc, a, b in zip(THIRD_OCT, bs, br):
        if math.isnan(a) or math.isnan(b):
            continue
        bands.append({"hz": round(fc), "sent_db": a, "recv_db": b, "diff_db": b - a, "diff_vs_mid_db": (b - a) - ref_diff})
    hf4 = db_pow(sr_["share_above_4k"]) - db_pow(ss["share_above_4k"])
    hf8 = db_pow(sr_["share_above_8k"]) - db_pow(ss["share_above_8k"])
    rolloff_ratio = sr_["rolloff95_hz"] / max(ss["rolloff95_hz"], 1.0)
    centroid_shift = sr_["centroid_hz"] - ss["centroid_hz"]
    r["spectrum"] = {
        "sent": ss, "recv": sr_,
        "bands": bands,
        "above_4k_share_change_db": hf4, "above_8k_share_change_db": hf8,
        "above_4k_abs_change_db": sr_["power_above_4k_db"] - ss["power_above_4k_db"],
        "above_8k_abs_change_db": sr_["power_above_8k_db"] - ss["power_above_8k_db"],
        "rolloff95_ratio": rolloff_ratio,
        "centroid_shift_hz": centroid_shift,
        "cutoff_hz_sent": cutoff_hz(bs), "cutoff_hz_recv": cutoff_hz(br),
    }
    r["muffled"] = muffled_verdict(r["spectrum"])

    # ---- endings and dropouts
    env_s_hf, env_r_hf = band_frame_db(sent, 4000, 16000), band_frame_db(recv, 4000, 16000)
    r["endings"] = analyze_endings(env_s, env_r, env_s_hf, env_r_hf, segs, thr)
    r["dropouts"] = analyze_dropouts(env_s, env_r, segs, thr, level_off)

    # ---- quality scores
    r["scores"] = quality_scores(sent, recv, mask)
    r["_internal"] = {"sent": sent, "recv": recv, "env_s": env_s, "env_r": env_r, "segs": segs,
                      "thr": thr, "bs": bs, "br": br}
    return r


def muffled_verdict(sp: dict) -> dict:
    fired = []
    if sp["above_4k_share_change_db"] <= HF4K_DROP_DB:
        fired.append(f"energy above 4 kHz down {sp['above_4k_share_change_db']:.1f} dB (limit {HF4K_DROP_DB})")
    if sp["above_8k_share_change_db"] <= HF8K_DROP_DB:
        fired.append(f"energy above 8 kHz down {sp['above_8k_share_change_db']:.1f} dB (limit {HF8K_DROP_DB})")
    if sp["rolloff95_ratio"] <= ROLLOFF_RATIO:
        fired.append(f"95% roll-off at {sp['rolloff95_ratio'] * 100:.0f}% of the sent one (limit {ROLLOFF_RATIO * 100:.0f}%)")
    if sp["centroid_shift_hz"] <= CENTROID_SHIFT_HZ:
        fired.append(f"spectral centroid down {-sp['centroid_shift_hz']:.0f} Hz (limit {-CENTROID_SHIFT_HZ:.0f})")
    strong = sp["above_4k_share_change_db"] <= 2 * HF4K_DROP_DB
    bw_limited = sp["cutoff_hz_sent"] > 0 and sp["cutoff_hz_recv"] < 0.8 * sp["cutoff_hz_sent"]
    if len(fired) >= 2 or strong:
        verdict = "MUFFLED"
    elif fired:
        verdict = "slightly duller"
    else:
        verdict = "no muffling"
    return {"verdict": verdict, "criteria_fired": fired, "bandwidth_limited": bool(bw_limited),
            "cutoff_hz_sent": sp["cutoff_hz_sent"], "cutoff_hz_recv": sp["cutoff_hz_recv"]}


def analyze_endings(env_s, env_r, hf_s, hf_r, segs, thr) -> dict:
    n = len(env_s)
    rows = []
    for k, (a, b) in enumerate(segs):
        nxt = segs[k + 1][0] if k + 1 < len(segs) else n
        core_idx = [i for i in range(a, b) if env_s[i] >= np.max(env_s[a:b]) - 15.0]
        gain = float(np.median(env_r[core_idx] - env_s[core_idx])) if core_idx else 0.0
        thr_r = thr + gain
        end_search = min(b + 30, nxt - 1, n)
        recv_end = a
        for i in range(a, end_search):
            if env_r[i] > thr_r:
                recv_end = i + 1
        truncated_frames = max(0, b - recv_end)
        t0 = max(a, b - 10)
        tail_s = db_pow(float(np.mean(10 ** (env_s[t0:b] / 10))))
        tail_r = db_pow(float(np.mean(10 ** (env_r[t0:b] / 10))))
        tail_loss = (tail_r - tail_s) - gain
        hs = db_pow(float(np.mean(10 ** (hf_s[t0:b] / 10))))
        hr = db_pow(float(np.mean(10 ** (hf_r[t0:b] / 10))))
        post_end = min(b + 30, nxt - 1, n)
        post_s = db_pow(float(np.mean(10 ** (env_s[b:post_end] / 10)))) if post_end > b else float("nan")
        post_r = db_pow(float(np.mean(10 ** (env_r[b:post_end] / 10)))) if post_end > b else float("nan")
        truncated = truncated_frames * HOP_MS >= TRUNCATED_MS or tail_loss <= TAIL_LOSS_DB
        rows.append({
            "segment": k + 1, "start_s": a * HOP_MS / 1000, "sent_end_s": b * HOP_MS / 1000,
            "recv_end_s": recv_end * HOP_MS / 1000, "length_ms": (b - a) * HOP_MS,
            "truncated_ms": truncated_frames * HOP_MS, "tail_loss_db": tail_loss,
            "tail_hf_change_db": (hr - hs) - gain, "level_gain_db": gain,
            "after_offset_300ms_sent_db": post_s, "after_offset_300ms_recv_db": post_r,
            "truncated": bool(truncated)})
    tr = [x for x in rows if x["truncated"]]
    return {
        "segments": rows,
        "share_truncated": len(tr) / len(rows) if rows else 0.0,
        "mean_truncated_ms": float(np.mean([x["truncated_ms"] for x in rows])) if rows else 0.0,
        "mean_truncated_ms_when_truncated": float(np.mean([x["truncated_ms"] for x in tr])) if tr else 0.0,
        "max_truncated_ms": max([x["truncated_ms"] for x in rows], default=0),
        "mean_tail_loss_db": float(np.mean([x["tail_loss_db"] for x in rows])) if rows else 0.0,
        "rule": f"truncated when the receiver stops >= {TRUNCATED_MS} ms before the sender, or the last 100 ms "
                f"lost >= {-TAIL_LOSS_DB:.0f} dB more than the body of the segment",
    }


def analyze_dropouts(env_s, env_r, segs, thr, level_off) -> dict:
    gaps = []
    for a, b in segs:
        end = max(a, b - 30)  # the last 300 ms is judged as the ending, not as a dropout
        i = a
        while i < end:
            bad = env_s[i] > thr and env_r[i] < thr + level_off - 12.0
            if bad:
                j = i
                while j < end and env_s[j] > thr and env_r[j] < thr + level_off - 12.0:
                    j += 1
                if (j - i) * HOP_MS >= 20:
                    gaps.append({"at_s": i * HOP_MS / 1000, "ms": (j - i) * HOP_MS})
                i = j
            else:
                i += 1
    return {"count": len(gaps), "total_ms": sum(g["ms"] for g in gaps),
            "longest_ms": max([g["ms"] for g in gaps], default=0), "gaps": gaps[:20],
            "rule": "speech frames (10 ms) in the sent signal that are >= 12 dB below the expected level in the "
                    "received one for >= 20 ms, outside the last 300 ms of a segment"}


def quality_scores(sent: np.ndarray, recv: np.ndarray, mask: np.ndarray) -> dict:
    out: dict = {}
    g = 16000
    s16 = signal.resample_poly(sent, 1, 3).astype(np.float64)
    r16 = signal.resample_poly(recv, 1, 3).astype(np.float64)
    # PESQ and STOI want matching levels; compare at the received speech level.
    rs, rr = np.sqrt(np.mean(s16 ** 2)) + EPS, np.sqrt(np.mean(r16 ** 2)) + EPS
    r16n = r16 * (rs / rr)
    try:
        from pesq import pesq  # type: ignore

        out["pesq_wb"] = float(pesq(g, s16.astype(np.float32), r16n.astype(np.float32), "wb"))
    except ImportError:
        out["pesq_wb"] = None
        out["pesq_note"] = "pesq not installed"
    except Exception as e:  # noqa: BLE001 (pesq raises its own errors for unusable input)
        out["pesq_wb"] = None
        out["pesq_note"] = f"pesq failed: {e}"
    try:
        from pystoi import stoi  # type: ignore

        out["stoi"] = float(stoi(s16, r16, g, extended=False))
        out["estoi"] = float(stoi(s16, r16, g, extended=True))
    except ImportError:
        out["stoi"] = None
        out["stoi_note"] = "pystoi not installed"
    except Exception as e:  # noqa: BLE001
        out["stoi"] = None
        out["stoi_note"] = f"stoi failed: {e}"
    return out


# ----------------------------------------------------------------------------------------------
# Reports
# ----------------------------------------------------------------------------------------------
def fmt(v, d=1, unit="") -> str:
    if v is None:
        return "n/a"
    if isinstance(v, float) and (math.isnan(v) or math.isinf(v)):
        return "n/a"
    return f"{v:.{d}f}{unit}"


def to_markdown(res: dict, label: str = "") -> str:
    L: list[str] = []
    title = f"## Audio comparison{': ' + label if label else ''}"
    L.append(title)
    if "error" in res:
        L += ["", f"**Error:** {res['error']}", ""]
        return "\n".join(L)
    d, lv, sp, mf, en, dr, sc = (res[k] for k in ("delay", "level", "spectrum", "muffled", "endings", "dropouts", "scores"))
    L += ["", "| Metric | Value |", "|---|---|"]
    L.append(f"| Delay (received later than sent) | {fmt(d['ms'], 1, ' ms')} (correlation {fmt(d['correlation'], 2)}) |")
    L.append(f"| Speech level sent / received | {fmt(lv['speech_rms_dbfs_sent'], 1)} / {fmt(lv['speech_rms_dbfs_recv'], 1)} dBFS (diff {fmt(lv['speech_level_diff_db'], 1, ' dB')}) |")
    L.append(f"| Peak difference | {fmt(lv['peak_diff_db'], 1, ' dB')} |")
    L.append(f"| Clipping sent / received | {lv['clipping_sent']['samples_at_full_scale']} / {lv['clipping_recv']['samples_at_full_scale']} samples at full scale |")
    L.append(f"| **Muffled verdict** | **{mf['verdict']}**{(' (' + '; '.join(mf['criteria_fired']) + ')') if mf['criteria_fired'] else ''} |")
    L.append(f"| Energy above 4 kHz (share of speech energy) sent / received | {fmt(sp['sent']['share_above_4k'] * 100, 1)} % / {fmt(sp['recv']['share_above_4k'] * 100, 1)} % ({fmt(sp['above_4k_share_change_db'], 1, ' dB')}) |")
    L.append(f"| Energy above 8 kHz sent / received | {fmt(sp['sent']['share_above_8k'] * 100, 2)} % / {fmt(sp['recv']['share_above_8k'] * 100, 2)} % ({fmt(sp['above_8k_share_change_db'], 1, ' dB')}) |")
    L.append(f"| Effective bandwidth (95 % roll-off) sent / received | {fmt(sp['sent']['rolloff95_hz'], 0)} / {fmt(sp['recv']['rolloff95_hz'], 0)} Hz (ratio {fmt(sp['rolloff95_ratio'], 2)}) |")
    L.append(f"| Spectral centroid sent / received | {fmt(sp['sent']['centroid_hz'], 0)} / {fmt(sp['recv']['centroid_hz'], 0)} Hz (shift {fmt(sp['centroid_shift_hz'], 0, ' Hz')}) |")
    L.append(f"| Highest band within 45 dB of peak sent / received | {fmt(mf['cutoff_hz_sent'], 0)} / {fmt(mf['cutoff_hz_recv'], 0)} Hz{' (bandwidth limited)' if mf['bandwidth_limited'] else ''} |")
    L.append(f"| **Segments truncated** | **{fmt(en['share_truncated'] * 100, 0)} %** of {len(en['segments'])} (mean tail cut {fmt(en['mean_truncated_ms'], 0, ' ms')}, max {en['max_truncated_ms']} ms; last 100 ms {fmt(en['mean_tail_loss_db'], 1, ' dB')} vs body) |")
    L.append(f"| Dropouts | {dr['count']} gaps, {dr['total_ms']} ms total, longest {dr['longest_ms']} ms |")
    L.append(f"| PESQ-WB | {fmt(sc.get('pesq_wb'), 2)} {sc.get('pesq_note', '')} |")
    L.append(f"| STOI / ESTOI | {fmt(sc.get('stoi'), 3)} / {fmt(sc.get('estoi'), 3)} {sc.get('stoi_note', '')} |")
    L += ["", "Third-octave long-term spectrum of the speech (dB, relative):", "",
          "| Hz | sent | received | diff | diff vs 0.5-2 kHz |", "|---|---|---|---|---|"]
    for b in sp["bands"]:
        L.append(f"| {b['hz']} | {b['sent_db']:.1f} | {b['recv_db']:.1f} | {b['diff_db']:+.1f} | {b['diff_vs_mid_db']:+.1f} |")
    L += ["", "Per segment endings (" + en["rule"] + "):", "",
          "| # | sent ends (s) | received ends (s) | truncated (ms) | last 100 ms vs body (dB) | HF tail (dB) | truncated |",
          "|---|---|---|---|---|---|---|"]
    for s in en["segments"]:
        L.append(f"| {s['segment']} | {s['sent_end_s']:.2f} | {s['recv_end_s']:.2f} | {s['truncated_ms']} | {s['tail_loss_db']:+.1f} | {s['tail_hf_change_db']:+.1f} | {'yes' if s['truncated'] else 'no'} |")
    if dr["gaps"]:
        L += ["", "Dropouts: " + ", ".join(f"{g['ms']} ms at {g['at_s']:.2f} s" for g in dr["gaps"])]
    L.append("")
    return "\n".join(L)


def to_json(res: dict) -> dict:
    return {k: v for k, v in res.items() if not k.startswith("_")}


def save_png(res: dict, path: str, label: str = "") -> bool:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    it = res["_internal"]
    fig, ax = plt.subplots(2, 2, figsize=(15, 9))
    for a, x, name in ((ax[0][0], it["sent"], "sent"), (ax[0][1], it["recv"], "received")):
        f, t, sxx = signal.spectrogram(x, fs=SR, nperseg=1024, noverlap=768, scaling="spectrum")
        im = a.pcolormesh(t, f / 1000, 10 * np.log10(sxx + 1e-14), vmin=-110, vmax=-30, shading="auto", cmap="magma")
        a.set_title(f"Spectrogram, {name}")
        a.set_xlabel("s")
        a.set_ylabel("kHz")
        a.set_ylim(0, 24)
        for hz in (4, 8):
            a.axhline(hz, color="w", lw=0.5, ls=":")
        fig.colorbar(im, ax=a, label="dB")
    b = ax[1][0]
    fcs = [fc for fc, x, y in zip(THIRD_OCT, it["bs"], it["br"]) if not (math.isnan(x) or math.isnan(y))]
    xs = [x for x in it["bs"] if not math.isnan(x)]
    ys = [y for y in it["br"] if not math.isnan(y)]
    b.semilogx(fcs, xs, "o-", label="sent")
    b.semilogx(fcs, ys, "s-", label="received")
    b.set_title("Long-term spectrum of the speech (third-octave)")
    b.set_xlabel("Hz")
    b.set_ylabel("dB")
    b.grid(True, which="both", alpha=0.3)
    b.legend()
    e = ax[1][1]
    t = np.arange(len(it["env_s"])) * HOP_MS / 1000
    e.plot(t, it["env_s"], label="sent", lw=0.8)
    e.plot(t[: len(it["env_r"])], it["env_r"], label="received", lw=0.8)
    e.axhline(it["thr"], color="gray", ls=":", lw=0.6)
    for s in res["endings"]["segments"]:
        e.axvline(s["sent_end_s"], color="g", lw=0.6)
        e.axvline(s["recv_end_s"], color="r" if s["truncated"] else "k", lw=0.6, ls="--")
    e.set_title("Envelope (10 ms RMS); green: sent ends, dashed: received ends (red: truncated)")
    e.set_xlabel("s")
    e.set_ylabel("dBFS")
    e.set_ylim(-100, 0)
    e.legend(loc="lower right")
    fig.suptitle(f"{label}  |  {res['muffled']['verdict']}  |  truncated {res['endings']['share_truncated'] * 100:.0f} %  |  delay {res['delay']['ms']:.0f} ms")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return True


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sent", required=True, help="WAV of what was sent (or the reference)")
    ap.add_argument("--received", required=True, help="WAV of what was received")
    ap.add_argument("--out-dir", default=".", help="where to write the .md, .json and .png")
    ap.add_argument("--name", default=None, help="base name of the output files (default: from --received)")
    ap.add_argument("--label", default="", help="title for the report")
    ap.add_argument("--max-lag", type=float, default=10.0, help="largest delay to look for, seconds")
    ap.add_argument("--no-png", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="do not print the Markdown")
    a = ap.parse_args(argv)
    sent, sr_s = read_wav(a.sent)
    recv, sr_r = read_wav(a.received)
    res = analyze(sent, sr_s, recv, sr_r, a.max_lag)
    os.makedirs(a.out_dir, exist_ok=True)
    base = a.name or os.path.splitext(os.path.basename(a.received))[0]
    label = a.label or base
    md = to_markdown(res, label)
    with open(os.path.join(a.out_dir, base + ".md"), "w", encoding="utf-8") as f:
        f.write(md)
    with open(os.path.join(a.out_dir, base + ".json"), "w", encoding="utf-8") as f:
        json.dump(to_json(res), f, indent=2)
    if "error" not in res and not a.no_png:
        if not save_png(res, os.path.join(a.out_dir, base + ".png"), label):
            print("matplotlib not installed: no PNG", file=sys.stderr)
    if not a.quiet:
        print(md)
    return 1 if "error" in res else 0


if __name__ == "__main__":
    sys.exit(main())
