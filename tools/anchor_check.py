#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
anchor_check.py —— 回答「色卡到底要拍多勤」的关键诊断。

结论先说：一张色卡一次性解出来的东西里，只有**一半**是一次性的。

  ① 斜率 γ（逐通道密度斜率比）
       = 胶片 + 冲洗的物理属性。同一型号的胶卷，γ 不变。
       **一次性**：按「胶片型号 × 扫描仪/店」各做一次。DiVERE 的 IDT 就是这个。

  ② 零点（"零曝光"落在密度轴的哪里）
       **不是一次性的** —— 它取决于每一帧能不能看到未曝光片基。
       而裁到画幅内的店扫件没有片基，只能拿「画面最亮的那撮像素」当代理，
       于是**零点就带上了那撮像素自己的颜色**。

本脚本量的就是 ②：对每一帧，看它最亮的 0.05% 像素是什么颜色，
换算成"相对于参考帧，这一帧的零点偏了几档"。

  · 各帧偏差都很小（≲0.2 档）→ 它们共用一个零点，**一张卡就够整卷**
  · 某一帧偏差很大（≳0.5 档）→ 那一帧的零点被自身的亮部颜色带偏了，
    这一帧的结果会带同量级的偏色，而**这套标定救不了它**（因为标定里没有那一帧的零点）

用法： python anchor_check.py <文件夹或文件...>
"""
import glob
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import demask as D

FRAC = 0.0005      # 取最亮的 0.05% 当零点代理（与 estimate_base 一致）


def anchor_colour(lin, frac=FRAC):
    """两件事一起量：
      (a) 「按亮度取最亮的 frac 像素」的颜色 —— 这是直觉上的零点代理，看它有多不中性；
      (b) estimate_base 实际用的「每通道各自最亮 frac 的均值」——
          这才是真正决定 Pi 零点的东西。

    为什么必须分开：estimate_base 是**逐通道**取最大，比「按亮度取」更接近真正的片基，
    也更能抵抗场景。诊断要针对真正在用的那个量。
    """
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    n = max(1, int(lin.shape[0] * lin.shape[1] * frac))
    thr = np.partition(lum.ravel(), -n)[-n]
    m = lum >= thr
    by_lum = np.median(lin[m].reshape(-1, 3), axis=0).astype(np.float64)
    dmin, _ = D.estimate_base(lin, top_frac=frac)
    return by_lum, dmin.astype(np.float64), int(np.count_nonzero(m))


def main(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(glob.glob(os.path.join(p, "*.TIF")) +
                            glob.glob(os.path.join(p, "*.tif")))
        else:
            files.append(p)
    if not files:
        print("没找到文件"); return

    rec = {}
    for f in files:
        im = cv2.imread(f)
        if im is None:
            continue
        lin = D.srgb_to_linear(im[:, :, ::-1].astype(np.float32) / 255.0)
        by_lum, dmin, npx = anchor_colour(lin)
        Dd = -np.log10(np.maximum(dmin, 1e-9))
        lg = np.log2(by_lum)
        rec[os.path.basename(f)] = {
            "anchor_by_lum_lin": [round(float(v), 5) for v in by_lum],
            "anchor_log2_RG": round(float(lg[0] - lg[1]), 4),
            "anchor_log2_BG": round(float(lg[2] - lg[1]), 4),
            "dmin_T": [round(float(v), 5) for v in dmin],
            "dmin_D": [round(float(v), 4) for v in Dd],
            "RG_D": round(float(Dd[0] - Dd[1]), 4),
            "BG_D": round(float(Dd[2] - Dd[1]), 4),
        }
        del im, lin

    names = list(rec)
    rg = np.array([rec[n]["RG_D"] for n in names])
    bg = np.array([rec[n]["BG_D"] for n in names])
    rgl = np.array([rec[n]["anchor_log2_RG"] for n in names])
    bgl = np.array([rec[n]["anchor_log2_BG"] for n in names])

    print(f"{'帧':22s}{'Dmin 密度 R/G/B':>26s}{'R−G (D)':>10s}{'B−G (D)':>10s}"
          f"{'最亮像素 log2 R/G':>18s}{'log2 B/G':>10s}")
    for n in names:
        r = rec[n]
        print(f"{n:22s}{str(r['dmin_D']):>26s}{r['RG_D']:>10.4f}{r['BG_D']:>10.4f}"
              f"{r['anchor_log2_RG']:>18.4f}{r['anchor_log2_BG']:>10.4f}")

    print("\n【诊断一】estimate_base 真正在用的量：片基密度的通道差")
    print(f"  R−G: 中位 {np.median(rg):+.4f}  极差 {rg.max()-rg.min():.4f} D"
          f"  = {(rg.max()-rg.min())/0.30103:.2f} 档")
    print(f"  B−G: 中位 {np.median(bg):+.4f}  极差 {bg.max()-bg.min():.4f} D"
          f"  = {(bg.max()-bg.min())/0.30103:.2f} 档")
    worstD = max(float(rg.max()-rg.min()), float(bg.max()-bg.min()))

    print("\n【诊断二】直觉上的零点代理：最亮像素有多不中性")
    print(f"  log2 R/G 极差 {rgl.max()-rgl.min():.4f}   log2 B/G 极差 {bgl.max()-bgl.min():.4f}")

    print(f"\n判读（按诊断一，因为那才是真正在用的量）：")
    if worstD / 0.30103 < 0.35:
        print("  ✅ ≤0.35 档：各帧零点一致 → 可以共用同一套标定，一张卡足够")
    elif worstD / 0.30103 < 0.8:
        print("  ⚠️ 0.35~0.8 档：有漂移，共用标定会带来同量级偏色，建议逐帧核对")
    else:
        print(f"  ❌ {worstD/0.30103:.2f} 档：漂移明显 → 这几帧不能共用一套标定")

    out = {"frames": rec,
           "RG_D_range": round(float(rg.max()-rg.min()), 4),
           "BG_D_range": round(float(bg.max()-bg.min()), 4),
           "implied_cast_stops": round(float(worstD/0.30103), 3),
           "anchor_log2_RG_range": round(float(rgl.max()-rgl.min()), 4),
           "anchor_log2_BG_range": round(float(bgl.max()-bgl.min()), 4)}
    op = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "anchor_check.json")
    json.dump(out, open(op, "w"), ensure_ascii=False, indent=1)
    print("→", op)


if __name__ == "__main__":
    args = sys.argv[1:] or ["./gold200"]
    main(args)
