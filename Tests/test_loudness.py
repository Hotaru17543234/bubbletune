"""响度算法的测试：EBU Tech 3341 标准测试题 + 和 ffmpeg 的 ebur128 对答案。

运行：cd Tests && python3 test_loudness.py
需要：numpy、scipy、soundfile；ffmpeg 有的话会多做一组对比
"""
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

import numpy as np

from loudness_model import gain_db, measure

FAILS = []


def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("  " + detail if detail else ""))
    if not ok:
        FAILS.append(name)


def sine(rate, seconds, dbfs, freq=1000.0):
    t = np.arange(int(rate * seconds)) / rate
    return (10 ** (dbfs / 20.0)) * np.sin(2 * math.pi * freq * t)


def stereo(x):
    return np.stack([x, x], axis=1)


# ---------- EBU Tech 3341 第 1~4 题（答案都是 -23.0 LUFS，误差 ±0.1） ----------

def test_ebu_3341():
    print("EBU Tech 3341")
    for rate in (44100, 48000):
        cases = {
            "1: 1kHz -23 dBFS 20s": stereo(sine(rate, 20, -23)),
            "2: 1kHz -33 dBFS 20s": stereo(sine(rate, 20, -33)),
            "3: -36/-23/-36": stereo(np.concatenate([sine(rate, 10, -36), sine(rate, 60, -23), sine(rate, 10, -36)])),
            "4: -72/-36/-23/-36/-72": stereo(np.concatenate([
                sine(rate, 10, -72), sine(rate, 10, -36), sine(rate, 60, -23),
                sine(rate, 10, -36), sine(rate, 10, -72)])),
        }
        expected = {"1": -23.0, "2": -33.0, "3": -23.0, "4": -23.0}
        for name, x in cases.items():
            got, _ = measure(x, rate)
            want = expected[name[0]]
            check(f"{rate} Hz case {name}", got is not None and abs(got - want) <= 0.1, f"got {got:.3f} want {want}")


def test_mono_is_dual_mono():
    print("单声道 = 两边一样的立体声")
    rate = 44100
    x = sine(rate, 10, -20, 440)
    mono, _ = measure(x, rate)
    st, _ = measure(stereo(x), rate)
    check("mono == stereo copy", abs(mono - st) < 1e-9, f"{mono:.4f} vs {st:.4f}")


def test_silence_and_short():
    print("没声音 / 太短")
    rate = 48000
    got, peak = measure(np.zeros((rate * 3, 2)), rate)
    check("all zeros -> None", got is None and peak is None)
    got, _ = measure(stereo(sine(rate, 0.3, -20)), rate)
    check("0.3 s -> None (不到一个 400ms 块)", got is None)
    got, _ = measure(stereo(sine(rate, 5, -80)), rate)
    check("-80 dBFS -> None (低于 -70 门限)", got is None)


def test_peak():
    print("峰值")
    rate = 44100
    x = stereo(sine(rate, 2, -6))
    x[1000, 1] = 0.9
    _, peak = measure(x, rate)
    check("peak 0.9", abs(peak - 20 * math.log10(0.9)) < 1e-9, f"{peak:.4f}")


# ---------- 和 ffmpeg 对答案（各种采样率、声道、像音乐的信号） ----------

def music_like(rate, seconds, seed, level_db):
    """粉红噪声 + 几个音，音量一会儿大一会儿小，中间有一段安静"""
    rng = np.random.default_rng(seed)
    n = int(rate * seconds)
    white = rng.standard_normal(n)
    # 简单的粉红化：频域 1/sqrt(f)
    spec = np.fft.rfft(white)
    f = np.fft.rfftfreq(n, 1 / rate)
    f[0] = f[1]
    pink = np.fft.irfft(spec / np.sqrt(f), n)
    pink /= np.max(np.abs(pink))
    t = np.arange(n) / rate
    tones = 0.3 * np.sin(2 * math.pi * 220 * t) + 0.2 * np.sin(2 * math.pi * 3300 * t)
    env = 0.6 + 0.4 * np.sin(2 * math.pi * 0.2 * t)
    x = (0.5 * pink + tones) * env
    quiet = (t > seconds * 0.4) & (t < seconds * 0.5)
    x[quiet] *= 0.01
    x *= 10 ** (level_db / 20.0) / np.max(np.abs(x))
    return x


def ffmpeg_lufs(path, dualmono):
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af",
           f"ebur128=dualmono={'true' if dualmono else 'false'}", "-f", "null", "-"]
    out = subprocess.run(cmd, capture_output=True, text=True).stderr
    m = re.findall(r"I:\s+(-?[\d.]+) LUFS", out)
    return float(m[-1]) if m else None


def test_against_ffmpeg():
    if not shutil.which("ffmpeg"):
        print("（没有 ffmpeg，跳过对比）")
        return
    import soundfile as sf
    print("和 ffmpeg ebur128 对比")
    tmp = tempfile.mkdtemp()
    combos = [(44100, 2), (48000, 2), (22050, 2), (44100, 1), (96000, 2), (32000, 1)]
    for i, (rate, ch) in enumerate(combos):
        left = music_like(rate, 30, i, -3.0)
        if ch == 1:
            x = left[:, None]
        else:
            right = music_like(rate, 30, i + 100, -5.0)
            x = np.stack([left, right], axis=1)
        path = os.path.join(tmp, f"t{i}.wav")
        sf.write(path, x, rate, subtype="FLOAT")
        ours, _ = measure(x, rate)
        ref = ffmpeg_lufs(path, dualmono=(ch == 1))
        ok = ref is not None and ours is not None and abs(ours - ref) <= 0.1
        check(f"{rate} Hz {ch}ch", ok, f"ours {ours:.2f} ffmpeg {ref}")
    shutil.rmtree(tmp)


# ---------- 调多少 dB ----------

def test_gain():
    print("播放时的增益")
    check("响的歌调小", abs(gain_db(-8.0, -0.1, -14.0) - (-6.0)) < 1e-9)
    check("小声的歌、峰值够低：整个调大", abs(gain_db(-20.0, -12.0, -14.0) - 6.0) < 1e-9)
    check("小声的歌、峰值很高：最多让防破音压 4 dB", abs(gain_db(-20.0, -1.0, -14.0) - 5.0) < 1e-9)
    check("调大最多 12 dB", abs(gain_db(-40.0, -30.0, -14.0) - 12.0) < 1e-9)
    check("调小最多 20 dB", abs(gain_db(10.0, 0.0, -14.0) - (-20.0)) < 1e-9)
    check("没测出来 -> 0", gain_db(None, None, -14.0) == 0.0)
    check("峰值超过 0 dBFS 时不靠余量", abs(gain_db(-20.0, 1.0, -14.0) - 4.0) < 1e-9)


if __name__ == "__main__":
    test_ebu_3341()
    test_mono_is_dual_mono()
    test_silence_and_short()
    test_peak()
    test_against_ffmpeg()
    test_gain()
    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED: {FAILS}")
        sys.exit(1)
    print("all passed ✨")
