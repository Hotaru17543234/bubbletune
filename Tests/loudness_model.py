"""App/Loudness.swift 的一比一 Python 版本，用来和 ffmpeg / pyloudnorm 对答案。

算法：ITU-R BS.1770-4 / EBU R128 的「整体响度」(integrated loudness, LUFS)
  1. K 计权滤波：两个二阶滤波器（高频搁架 + 高通），系数公式和 libebur128 一样
  2. 每 100 毫秒算一次各声道平方和（加权），4 个拼成 400 毫秒的块（重叠 75%）
  3. 绝对门限 -70 LUFS + 相对门限（比平均低 10 LU）去掉安静的部分，剩下的取平均
单声道当成「两个声道放一样的声音」（播放时左右喇叭都会响），权重 2。
"""
import math

import numpy as np


def k_weighting_coefficients(rate):
    """返回 [(b0,b1,b2,a1,a2) 高频搁架, (b0,b1,b2,a1,a2) 高通]"""
    f0 = 1681.974450955533
    G = 3.999843853973347
    Q = 0.7071752369554196
    K = math.tan(math.pi * f0 / rate)
    Vh = 10.0 ** (G / 20.0)
    Vb = Vh ** 0.4996667741545416
    a0 = 1.0 + K / Q + K * K
    shelf = ((Vh + Vb * K / Q + K * K) / a0,
             2.0 * (K * K - Vh) / a0,
             (Vh - Vb * K / Q + K * K) / a0,
             2.0 * (K * K - 1.0) / a0,
             (1.0 - K / Q + K * K) / a0)

    f0 = 38.13547087602444
    Q = 0.5003270373238773
    K = math.tan(math.pi * f0 / rate)
    d = 1.0 + K / Q + K * K
    highpass = (1.0, -2.0, 1.0,
                2.0 * (K * K - 1.0) / d,
                (1.0 - K / Q + K * K) / d)
    return [shelf, highpass]


def channel_weights(channels):
    if channels == 1:
        return [2.0]
    if channels == 2:
        return [1.0, 1.0]
    w = []
    for ch in range(channels):
        if channels == 6 and ch == 3:
            w.append(0.0)          # 5.1 的低音声道不算
        elif ch < 3:
            w.append(1.0)
        else:
            w.append(1.41)         # 环绕声道
    return w


def biquad(x, c):
    """Direct Form II transposed，和 Swift 版一样逐个样本算"""
    from scipy.signal import lfilter
    b0, b1, b2, a1, a2 = c
    return lfilter([b0, b1, b2], [1.0, a1, a2], x)


def measure(samples, rate):
    """samples: shape (frames, channels) 的 float 数组，范围 -1..1
    返回 (整体响度 LUFS 或 None, 采样峰值 dBFS 或 None)"""
    samples = np.asarray(samples, dtype=np.float64)
    if samples.ndim == 1:
        samples = samples[:, None]
    frames, channels = samples.shape
    weights = channel_weights(channels)
    coeffs = k_weighting_coefficients(rate)

    peak = float(np.max(np.abs(samples))) if frames else 0.0
    peak_db = 20.0 * math.log10(peak) if peak > 0 else None

    step = int(round(0.1 * rate))
    n_sub = frames // step
    if n_sub < 4:
        return None, peak_db

    weighted = np.zeros(frames)
    for ch in range(channels):
        if weights[ch] == 0:
            continue
        y = samples[:, ch]
        for c in coeffs:
            y = biquad(y, c)
        weighted += weights[ch] * y * y

    sub = weighted[: n_sub * step].reshape(n_sub, step).sum(axis=1)
    blocks = (sub[0:-3] + sub[1:-2] + sub[2:-1] + sub[3:]) / (4.0 * step)
    return integrate(blocks), peak_db


def integrate(blocks):
    """400 毫秒块的均方值 → 整体响度（两道门限）"""
    def lufs(z):
        return -0.691 + 10.0 * math.log10(z)

    above_abs = [z for z in blocks if z > 0 and lufs(z) > -70.0]
    if not above_abs:
        return None
    relative = lufs(sum(above_abs) / len(above_abs)) - 10.0
    gated = [z for z in above_abs if lufs(z) > relative]
    if not gated:
        return None
    return lufs(sum(gated) / len(gated))


# ---- 播放时调多少 dB（和 Swift 版 Loudness.gainDB / LoudnessMode 一样） ----

MAX_BOOST = 12.0          # 最多调大 12 dB
MAX_CUT = 20.0            # 最多调小 20 dB

# 两档：(目标响度, 调大时最响的地方最多让防破音压几 dB)
STANDARD = (-14.0, 4.0)
LOUD = (-10.0, 6.0)


def gain_db(loudness, peak_db, target, limiter_allowance=4.0):
    if loudness is None or not math.isfinite(loudness):
        return 0.0
    g = target - loudness
    if g > 0:
        headroom = -(peak_db if peak_db is not None else 0.0)
        g = min(g, max(0.0, headroom) + limiter_allowance)
    return max(-MAX_CUT, min(MAX_BOOST, g))
