#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
科学去色罩对照实验 v3 —— 在同一张真实负片上跑多套反相法。

输入：000021190026.TIF（Noritsu EZ Controller 输出，未反相负片，8-bit / sRGB tagged）

方法：
  A1 cineon_raw     Cineon 教科书原味：片基 = code 95，三通道共用负片 gamma 0.6
  A2 cineon_wb      Cineon + 三点白平衡（实际会这么做）
  B1 negadoctor     darktable 5.6.1 src/iop/negadoctor.c:238-322 逐行复刻，出厂默认 + 自动 Dmin/D_max
  B2 negadoctor_wb  同 B1，再解两根白平衡滑杆到暗部/亮部各自中性
  C  perchannel     逐通道 gamma（Negative Lab Pro 式）
  D  curvekept      各通道密度归一到绿色通道中性曲线（SpektraLab RFC-028 §6.2 "curve kept"）
"""

import os, json
import numpy as np
import cv2

ROOT = os.environ.get("NEGLAB_ROOT",
                                  os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC  = os.path.join(ROOT, "000021190026.TIF")
BASE = os.path.join(ROOT, "demask-test")
OUT, LOG = os.path.join(BASE, "out"), os.path.join(BASE, "logs")
os.makedirs(OUT, exist_ok=True); os.makedirs(LOG, exist_ok=True)

EPS = 1e-9
PI_MAX = 2.0
DT_THRESHOLD = 2.0 ** -32

def srgb_to_linear(x):
    x = np.asarray(x, dtype=np.float32)
    return np.where(x <= 0.04045, x / 12.92,
                    np.power((np.clip(x, 0.0, 1.0) + 0.055) / 1.055, 2.4)).astype(np.float32)

def linear_to_srgb(x):
    x = np.clip(np.asarray(x, dtype=np.float32), 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92,
                    1.055 * np.power(x, 1.0 / 2.4) - 0.055).astype(np.float32)

def save_png(path, rgb01, maxw=1600):
    a = np.clip(rgb01, 0, 1); h, w = a.shape[:2]
    if max(h, w) > maxw:
        s = maxw / max(h, w)
        a = cv2.resize(a, (int(w*s), int(h*s)), interpolation=cv2.INTER_AREA)
    cv2.imwrite(path, (a[:, :, ::-1]*255.0 + 0.5).astype(np.uint8))

def save_tiff16(path, rgb01):
    cv2.imwrite(path, ((np.clip(rgb01,0,1)*65535.0+0.5).astype(np.uint16))[:, :, ::-1])

def pct(a, p): return float(np.percentile(a, p))

# ---------------------------------------------------------------- 体检

def profile(rgb8):
    rep = {"shape": list(rgb8.shape), "channels": {}, "density_quantization": {}}
    for i, c in enumerate("RGB"):
        ch = rgb8[:, :, i].astype(np.float64)
        rep["channels"][c] = {
            "min": int(ch.min()), "max": int(ch.max()), "mean": round(float(ch.mean()), 2),
            "median": int(np.median(ch)), "p1": int(np.percentile(ch,1)),
            "p99": int(np.percentile(ch,99)), "p99.9": int(np.percentile(ch,99.9)),
            "unique_values": int(len(np.unique(ch))),
            "eff_bits": round(float(np.log2(max(len(np.unique(ch)),2))), 2),
            "zero_pct": round(float(100.0*(ch==0).mean()), 3),
            "sat_pct": round(float(100.0*(ch==255).mean()), 3),
        }
        codes = np.arange(1,255, dtype=np.float32)/255.0
        T = srgb_to_linear(codes); dD = np.log10(T[:-1]/T[1:])
        idx = np.arange(1,254)
        used = (np.percentile(ch,0.5) <= idx) & (idx <= np.percentile(ch,99.5))
        rep["density_quantization"][c] = {
            "median_step_D": round(float(np.median(dD[used])), 4),
            "max_step_D": round(float(np.max(dD[used])), 4),
            "step_D_at_code_16": round(float(dD[14]), 4),
            "step_D_at_code_64": round(float(dD[62]), 4),
            "step_D_at_code_128": round(float(dD[126]), 4),
        }
    return rep

# ---------------------------------------------------------------- 片基估计

def estimate_base(lin, top_frac=0.0005):
    """
    片基 = 未曝光透明区 = 透过率最高处。做法：
    先去噪（5x5 中值）压掉热噪点/颗粒，再取每通道最亮 top_frac 的均值。
    片基估得偏高→密度整体偏小；偏低→色罩没去干净。这一步是全流程最敏感的参数。
    """
    den = (np.clip(lin,0,1)*65535).astype(np.uint16)
    sm = np.stack([cv2.medianBlur(den[:,:,c], 5) for c in range(3)], axis=2).astype(np.float32)/65535.0
    n = max(1, int(sm.shape[0]*sm.shape[1]*top_frac))
    dmin = np.empty(3, np.float32)
    for c in range(3):
        v = sm[:,:,c].ravel()
        dmin[c] = np.partition(v, -n)[-n:].mean()
    return np.maximum(dmin, EPS), sm

def density_range(sm, dmin, bot_frac=0.01):
    """最密处 = 透过率最低的 bot_frac 的均值。用 1% 而不是 0.05%，
       否则被 8-bit 压到 0 的蓝通道会把密度范围撑成虚假的 7 个数量级。"""
    n = max(1, int(sm.shape[0]*sm.shape[1]*bot_frac))
    darkest = np.empty(3, np.float32)
    for c in range(3):
        v = sm[:,:,c].ravel()
        darkest[c] = max(np.partition(v, n-1)[:n].mean(), EPS)
    return darkest, np.log10(dmin/darkest)

# ---------------------------------------------------------------- 各方法

def _pi(lin, dmin):
    return -np.log10(np.clip(lin/dmin.reshape(1,1,3), 10.0**(-PI_MAX), 1.0))

def _pi_raw(lin, dmin):
    return -np.log10(np.maximum(lin/dmin.reshape(1,1,3), EPS))

def density_scales(lin, dmin, sample=500000, lo=0.05, hi=1.5, seed=0):
    """
    在密度域里用「过原点最小二乘」求各通道相对绿通道的密度斜率：
        Pi_c ≈ s_c * Pi_G
    只取三通道都落在 (lo, hi) 个数量级内的像素，避开片基平台与量化压死区。
    这是「curve kept / film terms」能不能成立的关键测量：
    s_c 应该全部 ≈1 才对（印片密度下三通道斜率本就该相等）。
    """
    Pi = _pi_raw(lin, dmin)
    h, w = Pi.shape[:2]
    rng = np.random.default_rng(seed)
    idx = rng.choice(h*w, size=min(sample, h*w), replace=False)
    P = Pi.reshape(-1, 3)[idx]
    m = np.all((P > lo) & (P < hi), axis=1)
    P = P[m]
    g = P[:, 1]
    return np.array([float((g*P[:, c]).sum() / max((g*g).sum(), EPS)) for c in range(3)], np.float32), int(m.sum())

def method_cineon(lin, dmin, gamma_neg=0.6):
    return np.maximum(np.power(10.0, _pi(lin,dmin)/gamma_neg) - 1.0, 0.0)

def method_perchannel(lin, dmin, gammas):
    g = np.array(gammas, np.float32).reshape(1,1,3)
    return np.maximum(np.power(10.0, _pi(lin,dmin)/g) - 1.0, 0.0)

def method_curvekept(lin, dmin, scales=None):
    """
    curve kept：把各通道密度按实测斜率归一到绿色中性曲线，再用绿色 gamma 反相。
    scales=None 时用「通道自身密度范围」代替（即不借助任何测量，纯猜）。
    """
    Pi = _pi(lin, dmin)
    if scales is None:
        ref = np.array([np.percentile(Pi[:,:,c], 99.5) for c in range(3)], np.float32)
        scales = ref[1] / np.maximum(ref, EPS)
    return np.maximum(np.power(10.0, (Pi/scales.reshape(1,1,3))/0.6) - 1.0, 0.0)

def method_negadoctor(lin, dmin, d_max, wb_high=(1.,1.,1.), wb_low=(1.,1.,1.),
                      offset=-0.05, black=0.0755, gamma=4.0, soft_clip=0.75, exposure=0.9245):
    """darktable 5.6.1 src/iop/negadoctor.c:238-322 逐行复刻"""
    Dmin = np.array(dmin, np.float32); wh = np.array(wb_high, np.float32); wl = np.array(wb_low, np.float32)
    wh_d = wh/d_max; off_c = wh*offset*wl; black_d = -exposure*(1.0+black)
    sc, sc_comp = soft_clip, 1.0-soft_clip
    clamped = np.maximum(lin, DT_THRESHOLD)
    log_den = -np.log10(np.maximum(Dmin.reshape(1,1,3)/clamped, EPS))
    de  = wh_d.reshape(1,1,3)*log_den + off_c.reshape(1,1,3)
    ten = np.power(10.0, np.clip(de, -20.0, 20.0))
    pl  = np.maximum(-(exposure*ten + black_d), 0.0)
    pg  = np.power(pl, gamma)
    e2g = np.exp(-(pg-sc)/sc_comp)
    return np.where(pg > sc, sc + (1.0-e2g)*sc_comp, pg).astype(np.float32)

def negadoctor_wb(lin, dmin, d_max, scales, **kw):
    """解两根白平衡滑杆：让三通道的 de 曲线与绿色对齐。
       de = (wb_high/D_max)*log_den → 要 de_c ∝ log_den_G，
       而 log_den_c = s_c*log_den_G，故 wb_high_c = wb_high_G / s_c。"""
    wb_high = tuple(float(np.clip(d_max/max(s, 1e-3), 0.25, 2.0)) for s in scales)
    return method_negadoctor(lin, dmin, d_max, wb_high=wb_high, wb_low=(1.,1.,1.), **kw), wb_high

# ---------------------------------------------------------------- 输出与度量

def display(L, ref_pct=99.9):
    w = max(pct(L[:,:,1], ref_pct), EPS)
    return linear_to_srgb(np.clip(L/w, 0.0, 1.0))

def cast_stops(a):
    """区域内三通道中位数的最大/最小比，单位：档"""
    m = np.maximum(np.median(a, axis=0), EPS)
    return round(float(np.log2(m.max()/m.min())), 3)

def metric(L, masks):
    out = {}
    for k, m in masks.items():
        if m.sum() > 32: out[f"cast_{k}_st"] = cast_stops(L[m])
    g = L[:,:,1]
    out["range_G_st"] = round(float(np.log2(max(pct(g,99.9),EPS)/max(pct(g,0.2),EPS))), 2)
    return out

# ---------------------------------------------------------------- main

def main():
    im = cv2.imread(SRC, cv2.IMREAD_UNCHANGED)
    rgb8 = im[:, :, ::-1].copy()
    x8 = rgb8.astype(np.float32)/255.0
    rep = profile(rgb8)

    lin = srgb_to_linear(x8)                       # 依 ICC 声明：sRGB 编码
    dmin, sm = estimate_base(lin)
    darkest, decades = density_range(sm, dmin)
    # D_max 取绿通道（最可靠的通道）；蓝通道被压到 0，测出的"密度范围"是假的
    d_max = float(np.clip(decades[1], 0.5, 2.5))
    print("Dmin(T) =", np.round(dmin,5), "密度范围(decades) =", np.round(decades,3),
          " D_max(取绿通道) =", round(d_max,3))

    lum = lin @ np.array([0.2126,0.7152,0.0722], np.float32)
    masks = {"white": lum <= np.percentile(lum,0.5),
             "mid":   (lum >= np.percentile(lum,35)) & (lum <= np.percentile(lum,65)),
             "dark":  lum <= np.percentile(lum,5.0)}

    gamma_guess = (0.50, 0.60, 0.72)
    scales_true, npx = density_scales(lin, dmin)
    gamma_equiv = 1.0/scales_true
    print(f"实测三通道密度斜率 s = {np.round(scales_true,4)}  （过原点最小二乘，{npx} 像素）")
    print(f"  → 等效每通道 gamma = {np.round(gamma_equiv,4)}   猜测值 = {gamma_guess}")
    print(f"  → 猜测与实测的最大偏差 = {float(np.max(np.abs(np.log2(gamma_equiv/np.array(gamma_guess))))):.2f} 档")

    methods = {}
    methods["A1_cineon_raw"]    = (method_cineon(lin, dmin), "Cineon 原味 · 三通道共用 gamma 0.6，无白平衡")
    methods["A2_cineon_wb"]     = (method_curvekept(lin, dmin, scales_true), "Cineon + 用实测斜率归一（= 印片密度白平衡）")
    methods["B1_negadoctor"]    = (method_negadoctor(lin, dmin, d_max), "negadoctor · darktable 默认 + 自动 Dmin/D_max")
    nb2, wbh = negadoctor_wb(lin, dmin, d_max, scales_true)
    methods["B2_negadoctor_wb"] = (nb2, "negadoctor · 再解两根白平衡滑杆")
    methods["C_perchannel"]     = (method_perchannel(lin, dmin, gamma_guess), "逐通道 gamma（NLP 式）· gamma 靠猜")
    methods["D_curvekept"]      = (method_curvekept(lin, dmin, None), "curve kept · 曲线只从画面里猜")

    save_png(os.path.join(OUT, "01_输入_原样.png"), x8)

    summary = {}
    for name, (L, label) in methods.items():
        save_png(os.path.join(OUT, f"10_{name}.png"), display(L))
        save_tiff16(os.path.join(OUT, f"10_{name}.tif"), np.clip(L/max(pct(L[:,:,1],99.9),EPS),0,1))
        summary[name] = {"label": label, **metric(L, masks)}
        print(f"  {name:20s} {summary[name]}")

    # 100% 裁切对照
    h, w = lin.shape[:2]
    for cname,(y,x,ch,cw) in {"shadow":(int(h*0.05),int(w*0.30),600,600),
                              "midtone":(int(h*0.42),int(w*0.28),600,600),
                              "highlight":(int(h*0.55),int(w*0.02),600,600)}.items():
        tiles=[x8[y:y+ch,x:x+cw]]+[display(L)[y:y+ch,x:x+cw] for L,_ in methods.values()]
        save_png(os.path.join(OUT,f"20_crop_{cname}.png"), np.concatenate(tiles,axis=1), maxw=6000)

    json.dump({"input_profile":rep,"dmin":[float(v) for v in dmin],"d_max":d_max,
               "decades":[float(v) for v in decades],
               "density_scales":[float(v) for v in scales_true],
               "gamma_equiv":[float(v) for v in gamma_equiv],
               "negadoctor_wb_high":[float(v) for v in wbh],
               "methods":summary},
              open(os.path.join(LOG,"summary.json"),"w"), ensure_ascii=False, indent=2)
    print("\n输出：", OUT)

if __name__ == "__main__":
    main()
