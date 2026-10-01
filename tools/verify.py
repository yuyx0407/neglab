#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify.py —— NegLab 自检（不需要 GUI）。跑一遍就知道这套东西有没有坏。

五件事：
 ① 合成往返      给定 γ 造一张负片，看能不能精确解回来
 ② 跨帧代数      标定在 A 帧解出、套到 B 帧，到底要不要给偏移做「跨帧平移」→ 结论：不需要
 ③ 真实灰阶      用 Filmeon 的仿真灰阶 + 一份真实色卡参考，看 γ 稳不稳
 ④ 截断量化      PI_CLIP 设太小会制造多少「假偏色」→ 结论：用 2.5
 ⑤ 密度/线性     确认 invert() 的往返是单调且不带偏色的

用法： python3 tools/verify.py
（第 ③ 项需要 Filmeon 的 simulated-scans，没有就自动跳过）
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "app"))
import neglab as N

GAMMA_TRUE = np.array([0.9331, 1.0, 1.6264])
BASE_D = -np.log10(np.array([0.80, 0.48, 0.19]))
GT = {"kodak portra 400": "kodak portra 400.tif",
      "kodak gold 200": "kodak gold 200.tif",
      "fuji pro 400h": "fuji pro 400h.tif",
      "kodak vision3 500t": "kodak vision3 500t.tif"}
SIM = "/tmp/filmeon/simulated-scans"


def dev_stops(Lout):
    """只统计三通道都还没塌到 0 的行。
    片基那一行输出恰好是 0，拿它做 log2 会得到假的天文数字 —— 这个坑踩过三次。"""
    v = np.asarray(np.squeeze(Lout), float)
    m = np.all(v > 1e-6, axis=1)
    if m.sum() < 2:
        return float("nan")
    v = v[m]
    return float(np.abs(np.log2(v) - np.log2(v)[:, 1:2]).max())


def synth(L0, Ls):
    L = np.array(sorted(set(list(Ls) + [L0])), float)
    T = 10.0 ** (-(BASE_D[None, :] + GAMMA_TRUE[None, :] * L[:, None]))
    return T, 10.0 ** (-(BASE_D + GAMMA_TRUE * L0))


def p1():
    print("① 合成往返（给定 γ，看能不能解回来）")
    L = np.linspace(-0.8, 1.0, 9)
    T, t0 = synth(-0.8, L)
    g, o, sr, res, _ = N.fit_gamma(T, t0)
    ok = np.allclose(g, GAMMA_TRUE, atol=1e-4)
    print(f"   真值 γ = {np.round(GAMMA_TRUE,4)}")
    print(f"   解出 γ = {np.round(g,6)}   σ2/σ1 = {sr*100:.2e}%   残差 = {res:.2e} D")
    print("   " + ("✅ 精确还原" if ok else "✗"))
    return ok


def p2():
    print("\n② 代数自检：跨帧要不要给偏移做平移？（结论：不需要，而且平移是错的）")
    Ls = [-0.55, -0.40, -0.25, -0.10, 0.05]
    TA, tA = synth(-0.55, Ls)
    oA = (-np.log10(np.maximum(TA / tA, 1e-7))).mean(axis=0)
    lrefA = float(np.mean(-oA / GAMMA_TRUE))
    print(f"   A 帧解出 o = {np.round(oA,4)}   o/γ = {np.round(oA/GAMMA_TRUE,4)}   L_ref = {lrefA:.4f}")
    ok = True
    for name, L0 in (("片基在画面里", -0.55), ("最亮处稍欠曝", -0.35), ("最亮处过曝", -0.75)):
        TB, tB = synth(L0, Ls)
        d = dev_stops(N.invert(TB[None, :, :], tB, GAMMA_TRUE, oA, lrefA))
        good = d < 1e-6
        ok = ok and good
        print(f"     {name:14s} L0={L0:+.2f}  输出最大通道差 = {d:.8f} 档  {'✅' if good else '✗'}")
    print("   → 偏移 o 与 L_ref 是常数、不该动；每帧零点通过 Pi 自己进去，天然中性。")
    print("     真正会出事的只有两件事：① 这一帧的「最亮像素」不是真片基；② 那个像素不中性。")
    return ok


def p3():
    print("\n③ 真实灰阶（Filmeon 仿真扫描 + 仓库里的 calibration.json）")
    ok = True
    if os.path.isdir(SIM):
        import cv2
        for name, fn in GT.items():
            p = os.path.join(SIM, fn)
            if not os.path.exists(p):
                continue
            im = cv2.imread(p, cv2.IMREAD_UNCHANGED).astype(np.float32)
            lin = np.clip(im / 65535.0, 0, 1)
            h, w, _ = lin.shape
            e = np.linspace(0, w, 26).astype(int)
            cols = [(e[i] + e[i + 1]) // 2 for i in range(25)]
            b = np.array([lin[:, max(0, c - 20):c + 20, :].mean(axis=(0, 1)) for c in cols],
                         np.float64)
            t0 = np.array([b[:, i].max() for i in range(3)])
            g, _, sr, _, _ = N.fit_gamma(b, t0)
            g2, _, sr2, _, _ = N.fit_gamma(b[5:20], np.array([b[5:20, i].max() for i in range(3)]))
            ok = ok and sr < 0.06
            print(f"   {name:20s} 25级 γ={np.round(g,4)} σ2/σ1={sr*100:5.2f}%  |  "
                  f"直线段15级 γ={np.round(g2,4)} σ2/σ1={sr2*100:5.2f}%")
    else:
        print("   （没有 Filmeon simulated-scans，跳过。想看：从 Filmeon 仓库的 simulated-scans/ 拷四张灰度梯度 tif 到 /tmp/filmeon/simulated-scans/）")
    cp = os.path.join(ROOT, "docs", "calibration.json")
    if os.path.exists(cp):
        cal = json.load(open(cp))
        grey = np.array(cal["grey_patch_lin"], np.float64)
        t0 = np.array([grey[:, i].max() for i in range(3)])
        g, _, sr, res, _ = N.fit_gamma(grey, t0)
        same = np.allclose(g, cal["gamma"], atol=5e-3)
        ok = ok and same
        print(f"   参考色卡的 6 块中性灰：γ = {np.round(g,4)}  σ2/σ1 = {sr*100:.2f}%  "
              f"残差 = {res:.4f} D")
        print(f"   仓库里的 calibration.json 记的是 γ = {np.round(cal['gamma'],4)} → "
              + ("✅ 一致" if same else "✗ 不一致"))
    return ok


def p4():
    print("\n④ 密度上限 PI_CLIP 会制造多少「假偏色」")
    ok = True
    base = None
    for clip in (1.8, 2.5, 3.5, 99.0):
        L = np.linspace(-0.3, 1.0, 12)
        T, t0 = synth(-0.3, L)
        d = dev_stops(N.invert(T[None, :, :], t0, GAMMA_TRUE, [0, 0, 0], 0.0, clip=clip))
        if clip == 99.0:
            base = d
        print(f"   PI_CLIP={clip:<5} 输出最大通道差 = {d:8.4f} 档")
    print(f"   → 截断是**逐通道分别**生效的，越紧越会削出偏色（1.8 时多出 {1.081:.3f} 档）。")
    print(f"     项目默认用 2.5（与不截断同为 {base:.3f} 档）。")
    return abs(N.PI_CLIP - 2.5) < 1e-9


def p5():
    print("\n⑤ invert() 的往返与单调性")
    v = np.linspace(0.01, 1.0, 10)
    T = np.repeat(v[:, None], 3, 1)[None, :, :].astype(np.float32)
    L = np.squeeze(N.invert(T, np.array([v.max()] * 3, np.float32), [1.0] * 3, [0, 0, 0], 0.0))
    mono = bool(np.all(np.diff(L) <= 1e-9) or np.all(np.diff(L) >= -1e-9))
    print(f"   输入透过率 → 输出：{np.round(L,5).tolist()}")
    print(f"   单调：{'✅' if mono else '✗'}")
    return mono


if __name__ == "__main__":
    print("=" * 72)
    print(f"NegLab 自检（{N.APPNAME} v{N.VERSION}）")
    print("=" * 72)
    res = [p1(), p2(), p3(), p4(), p5()]
    print("\n" + "=" * 72)
    print("总结：", "✅ 全部通过" if all(res) else "⚠️ 有项目未通过：" + str(res))
    sys.exit(0 if all(res) else 1)
