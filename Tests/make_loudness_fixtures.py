"""生成给 Swift 检查程序（Tests/LoudnessCheck）用的测试音频和标准答案。

用法：python3 make_loudness_fixtures.py 输出文件夹
会写出若干 .wav（32 位浮点）和 expected.json：
  { "文件名": {"rate":..., "channels":..., "lufs":..., "peak_db":...}, ... }
答案用 loudness_model.py 算（它已经和 ffmpeg、EBU 标准测试题对过）。
"""
import json
import math
import os
import sys

import numpy as np
import soundfile as sf

from loudness_model import measure
from test_loudness import music_like, sine


def with_hits(x, rate, hit_db):
    """每秒加一下很短的「鼓点」，让峰值很高、但整体响度几乎不变"""
    x = x.copy()
    amp = 10 ** (hit_db / 20.0)
    n = int(0.004 * rate)
    t = np.arange(n) / rate
    burst = amp * np.sin(2 * math.pi * 900 * t) * np.hanning(n)
    for start in range(rate // 2, len(x) - n, rate):
        x[start:start + n] += burst
    return x


def main(out):
    os.makedirs(out, exist_ok=True)
    fixtures = {}

    def add(name, x, rate):
        x = np.asarray(x, dtype=np.float32)
        if x.ndim == 1:
            x = x[:, None]
        sf.write(os.path.join(out, name), x, rate, subtype="FLOAT")
        lufs, peak = measure(x.astype(np.float64), rate)
        fixtures[name] = {"rate": rate, "channels": int(x.shape[1]), "lufs": lufs, "peak_db": peak}

    # 各种采样率 / 声道，和 Python 版逐个对答案
    for i, (rate, ch) in enumerate([(44100, 2), (48000, 2), (22050, 2), (44100, 1), (96000, 2), (32000, 1)]):
        left = music_like(rate, 20, i, -3.0)
        if ch == 1:
            add(f"mix_{rate}_{ch}ch.wav", left, rate)
        else:
            right = music_like(rate, 20, i + 100, -5.0)
            add(f"mix_{rate}_{ch}ch.wav", np.stack([left, right], axis=1), rate)

    rate = 44100
    # EBU Tech 3341 第 1 题（答案 -23.0）
    add("ebu_case1.wav", np.stack([sine(rate, 20, -23)] * 2, axis=1), rate)

    # 播放链测试用：小声且峰值低 / 小声但峰值高 / 很响
    quiet = music_like(rate, 20, 7, -16.0)
    add("quiet_lowpeak.wav", np.stack([quiet, quiet * 0.9], axis=1), rate)
    soft = music_like(rate, 20, 8, -14.0)
    hit = with_hits(soft, rate, -1.0)
    add("quiet_highpeak.wav", np.stack([hit, hit], axis=1), rate)
    loud = music_like(rate, 20, 9, -0.1)
    loud = np.tanh(loud * 3.0) / np.tanh(3.0) * 10 ** (-0.1 / 20)   # 压得很满的现代母带
    add("loud.wav", np.stack([loud, loud], axis=1), rate)
    add("mono_quiet.wav", music_like(rate, 20, 10, -10.0), rate)

    with open(os.path.join(out, "expected.json"), "w") as f:
        json.dump(fixtures, f, indent=1)
    for k, v in fixtures.items():
        print(f"{k:24s} {v['rate']:6d} Hz {v['channels']}ch  {v['lufs']:.2f} LUFS  peak {v['peak_db']:.2f} dBFS")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/fixtures")
