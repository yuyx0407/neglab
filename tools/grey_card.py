#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
grey_card.py —— 用色卡上那条灰阶反解「逐通道偏移 + 逐通道斜率」，再反相整帧。

为什么这件事值得单独写一个脚本：

  前七轮里我们反复撞到同一堵墙：**从画面内容反推片基和斜率是可解的，但解不唯一**
  （第六轮：三条同样合理的选点规则，同一帧 R:B 差 0.48 / 1.08 / 0.82 档；
  第七轮：真帧上的"漂移"主要由场景决定，不能用来选方法）。

  已知中性的灰阶把这个不适定问题变成适定问题。数学很简单：

    灰色块 k 的反射率 ρ_k 是已知相等的（在三通道意义上），光照也相同，所以
        曝光_c(k) = E0 · ρ_k · ∫I(λ)S_c(λ)dλ
        logE_c(k) = logE0 + logρ_k + k_c
        D_c(k)    = γ_c · logρ_k + const_c
    即    Pi_c(k) = o_c + γ_c · L_k      （L_k = 与通道无关的公共曝光坐标）

  所以把 6×3 的密度矩阵去均值后应该**秩 1**。秩 1 检验同时也是"这六格真的是
  中性的吗"的检验 —— 第二奇异值占第一的比例就是答案。

  分解出来直接得到：
    γ 方向  = 逐通道斜率比（= 我们找了七轮的 s_c）
    列均值  = 逐通道偏移（= 白平衡）
  而且验证点是 6 个（每一级灰阶），不是 1 个。
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import demask as D
import chart_extract as CE

BASE = ROOT
# ------------------------------------------------------------------ 取样

def sample_patches(lin, centres):
    """在**线性透过率**上取每格中心 60%，迭代修剪中位数。"""
    out = []
    for p in centres:
        cx, cy, pw, ph = p["cx"], p["cy"], p["pw"], p["ph"]
        hw, hh = int(pw * 0.20), int(ph * 0.20)
        v = lin[cy - hh:cy + hh + 1, cx - hw:cx + hw + 1].reshape(-1, 3).astype(np.float64)
        for _ in range(3):
            med = np.median(v, axis=0)
            d = np.linalg.norm(v - med, axis=1)
            k = d <= np.percentile(d, 60)
            if k.sum() < 16:
                break
            v = v[k]
        out.append(np.median(v, axis=0))
    return np.array(out, np.float64)


# ------------------------------------------------------------------ 拟合

def rank1_svd(Pi):
    """去均值后的秩 1 分解。返回 (γ方向, σ2/σ1, 残差最大绝对值, 公共曝光)。"""
    C = Pi - Pi.mean(axis=0, keepdims=True)
    _, s, vt = np.linalg.svd(C, full_matrices=False)
    g = vt[0]
    if g[1] < 0:
        g = -g
    L = C[:, 1] / max(g[1], 1e-12)
    resid = C - np.outer(L, g)
    return g, float(s[1] / max(s[0], 1e-12)), float(np.abs(resid).max()), L


def fit_calibration(patch_lin, col_index, dmin):
    """patch_lin: 该列 6 格 x 3 通道的线性透过率。返回标定字典。"""
    Pi = -np.log10(np.maximum(patch_lin, 1e-7)) - (-np.log10(np.maximum(dmin, 1e-7)))
    g, ratio, resid, L = rank1_svd(Pi)
    gamma = g / g[1]                     # 归一化到绿通道
    o = Pi.mean(axis=0)
    # 片基（Pi = 0）在该模型下的名义曝光：L_c = (Pi_c − o_c)/γ_c  →  −o_c/γ_c
    Lb = -o / np.maximum(gamma, 1e-12)
    return {"gamma": gamma, "gamma_raw": g, "offset": o, "L": L,
            "rank1_resid_D": round(resid, 4), "sigma2_over_sigma1_pct": round(ratio * 100, 2),
            "col": col_index, "L_base": float(np.mean(Lb)),
            "L_base_per_channel": [round(float(v), 4) for v in Lb]}


def exposure_coord(lin, dmin, cal, clip=1.8, floor=True):
    """逐通道曝光坐标 L_c = (Pi_c − o_c)/γ_c，再减掉片基的名义曝光。

    三通道**各自保留**（中性处它们天然相等 → 输出中性；有色处不等 → 颜色保留）。
    ⚠️ 曾经写成取三通道中位数 —— 那样输出就是一张灰图，颜色全丢。

    floor=True：把 L − L_base 截到 ≥ 0。模型外推到片基时三通道会差 0.04 左右，
    不截的话暗部会留一点染色；截掉等于承认"模型管不到片基以下"。
    """
    g = np.asarray(cal["gamma"], np.float32)
    o = np.asarray(cal["offset"], np.float32)
    x = np.clip(lin / dmin.reshape(1, 1, 3), 10.0 ** (-clip), 1.0)
    Pi = -np.log10(np.maximum(x, 1e-7))
    del x
    L = (Pi - o.reshape(1, 1, 3)) / g.reshape(1, 1, 3)
    del Pi
    L -= np.float32(cal["L_base"])
    if floor:
        np.maximum(L, 0.0, out=L)
    return L


def apply_calibration(lin, dmin, cal, gamma_out=0.6, clip=1.8, floor=True):
    """逐通道公共曝光 → 反相（gamma_out = 0.6，与其它方法同一口径以便比较）。"""
    L = exposure_coord(lin, dmin, cal, clip, floor)
    np.power(10.0, L / gamma_out, out=L)
    L -= 1.0
    np.maximum(L, 0.0, out=L)
    return L


# ------------------------------------------------------------------ 主流程

def col_indices(col_index, page):
    """centres 的排列是：左页 24 格（行主序 r1c1..r1c4, r2c1..），再右页 24 格。
    col_index 1..4 = 该页的列号，page 0=左页 1=右页。返回该列的 6 个下标。"""
    off = 0 if page == 0 else 24
    return [off + (col_index - 1) + 4 * r for r in range(6)]


def analyse(src, chart_bboxes, verbose=True):
    im = cv2.imread(src)
    rgb8 = im[:, :, ::-1].astype(np.float32) / 255.0
    lin = D.srgb_to_linear(rgb8)
    Ldisp, dmin, dmax = CE.invert(lin)
    disp = (D.linear_to_srgb(np.clip(Ldisp / max(float(np.percentile(Ldisp[:, :, 1], 99.9)), 1e-9), 0, 1))
            [:, :, ::-1] * 255).astype(np.uint8)

    centres = []
    for tag, bbox in chart_bboxes:
        _, _, cen = CE.detect(disp, bbox)
        for p in cen:
            p["page"] = tag
        centres += cen
    if verbose:
        print(f"{os.path.basename(src)}: 检出 {len(centres)} 格，dmin(T)={np.round(dmin,4)}")
    if len(centres) != 48:
        raise RuntimeError(f"格子数不对（{len(centres)} ≠ 48），检查 bbox 与 klen")

    vals = sample_patches(lin, centres)

    # 哪一列最"中性"？逐列做秩 1 检验，σ2/σ1 最小的那一列就是灰阶
    report = []
    for ci in range(8):
        page, col = (0, ci + 1) if ci < 4 else (1, ci - 3)
        idx = col_indices(col, page)
        Pi = -np.log10(np.maximum(vals[idx], 1e-7)) - (-np.log10(np.maximum(dmin, 1e-7)))
        g, ratio, resid, _ = rank1_svd(Pi)
        report.append({"col_index": ci + 1, "page": "左" if page == 0 else "右",
                       "rank1_resid_D": round(resid, 4),
                       "sigma2_over_sigma1_pct": round(ratio * 100, 2),
                       "gamma_ratio": [round(float(v / g[1]), 3) for v in g]})
    report.sort(key=lambda r: r["sigma2_over_sigma1_pct"])
    if verbose:
        print("  各列的秩 1 检验（越小越中性）：")
        for r in report:
            print(f"    {r['page']}页第{r['col_index'] if r['page']=='左' else r['col_index']-4}列"
                  f"  σ2/σ1={r['sigma2_over_sigma1_pct']:6.2f}%"
                  f"  最大残差={r['rank1_resid_D']:.4f} D  γ比={r['gamma_ratio']}")

    best = report[0]["col_index"] - 1
    page, col = (0, best + 1) if best < 4 else (1, best - 3)
    idx = col_indices(col, page)
    cal = fit_calibration(vals[idx], best + 1, dmin)
    cal["chosen_col"] = best + 1
    cal["col_ranking"] = report
    cal["grey_patch_lin"] = [[round(float(v), 5) for v in vals[i]] for i in idx]
    cal["dmin"] = [round(float(v), 5) for v in dmin]
    return cal, lin, dmin, disp, centres, vals


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else \
        "./gold200/000364980009.TIF"
    cal, lin, dmin, disp, cen, vals = analyse(
        src, (("左页", (1615, 2265, 1240, 2190)), ("右页", (2395, 3010, 1240, 2190))))
    print(f"\n选中的灰阶列：第 {cal['chosen_col']} 列")
    print(f"  逐通道斜率比 γ (R:G:B) = {np.round(cal['gamma'], 4)}")
    print(f"  逐通道偏移 o           = {np.round(cal['offset'], 4)} D")
    print(f"  秩 1 残差最大 {cal['rank1_resid_D']} D，σ2/σ1 = {cal['sigma2_over_sigma1_pct']}%")
    print(f"  公共曝光 L（白→黑）= {np.round(cal['L'], 4)}")
