#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
demask_pipeline.py —— 把八轮实验压成的一条可执行流水线。

三件事，和 SOP 的三个阶段一一对应：

  check      输入体检 + 零点体检（决定"救不救得回来、能不能共用一套标定"）
  calibrate  从一帧灰阶色卡解出 γ（逐通道密度斜率比）→ calibration.json
  apply      用 γ + 该帧自己的零点反相整卷，并给出验收读数

核心只有三行数学（其余全是体检和验收）：

    Pi_c = -log10( clip(T_c / T0_c) )              # 相对零点的密度
    L_c  = (Pi_c - o_c) / γ_c                      # 逐通道曝光坐标
    out_c = 10 ** ((L_c - L_ref) / 0.6) - 1        # 反相（γ_out=0.6，与其它方法同口径）

  零点 T0_c 有两种来源，这是全流程最关键的选择：
    · base  —— 画面里的未曝光片基。**精确、帧帧独立**；此时 o_c = 0、L_ref = 0
    · scene —— 画面最亮 0.05%（每通道）。**免费但会被场景带偏**（实测同卷漂 0.37~0.49 档）
              用这种模式时，o_c 与 L_ref 必须来自 calibration.json

用法：
  python demask_pipeline.py check     <文件或文件夹> [...]
  python demask_pipeline.py calibrate <色卡帧.tif> [--col auto]
  python demask_pipeline.py apply     <文件或文件夹> [...] [--zero scene|base]
                                      [--cal demask-test/logs/calibration.json]
                                      [--out demask-test/out9]
"""
import argparse
import glob
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import demask as D
import chart_extract as CE
import grey_card as GC

DEF_CAL = os.path.join(HERE, "logs", "calibration.json")
GAMMA_OUT = 0.6
CLIP_PI = 1.8
CHART_BBOX = (("左页", (1615, 2265, 1240, 2190)), ("右页", (2395, 3010, 1240, 2190)))


# ------------------------------------------------------------------ 公共

def expand(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(glob.glob(os.path.join(p, "*.TIF")) +
                          glob.glob(os.path.join(p, "*.tif")))
        elif os.path.isfile(p):
            out.append(p)
    return out


def load_linear(path):
    im = cv2.imread(path)
    if im is None:
        raise RuntimeError("读不了 " + path)
    return D.srgb_to_linear(im[:, :, ::-1].astype(np.float32) / 255.0)


def zero_scene(lin):
    """零点模式 scene：每通道最亮 0.05% 的均值（= demask.estimate_base）。"""
    t0, _ = D.estimate_base(lin)
    return np.maximum(t0, 1e-6), "scene"


def zero_base(lin, frac=0.06):
    """零点模式 base：用画面四条边框的**未曝光片基**。

    只在"店家没有把画幅裁到边"时成立。做法：取上下各 frac/2、左右各 frac/2
    宽度的边条，去掉明显不是片基的像素（比该通道中位数低太多的），再取每通道
    最亮 20% 的均值。若边条里没有足够的片基像素（>50% 被剔除），返回 None。
    """
    h, w = lin.shape[:2]
    bh, bw = max(2, int(h * frac / 2)), max(2, int(w * frac / 2))
    strips = [lin[:bh], lin[-bh:], lin[:, :bw], lin[:, -bw:]]
    px = np.concatenate([s.reshape(-1, 3) for s in strips], axis=0).astype(np.float64)
    t0 = np.empty(3)
    for c in range(3):
        v = px[:, c]
        v = v[v >= np.percentile(v, 50)]          # 片基是边条里最亮的那部分
        if v.size < 0.25 * px.shape[0]:           # 片基像素太少 → 边条不是片基
            return None, "base(失败)"
        n = max(1, int(v.size * 0.20))
        t0[c] = float(np.partition(v, -n)[-n:].mean())
    return np.maximum(t0, 1e-6), "base"


def invert_with(lin, t0, gamma, offset=(0.0, 0.0, 0.0), l_ref=0.0, clip=CLIP_PI):
    x = np.clip(lin / t0.reshape(1, 1, 3), 10.0 ** (-clip), 1.0)
    Pi = -np.log10(np.maximum(x, 1e-7))
    del x
    g = np.asarray(gamma, np.float32).reshape(1, 1, 3)
    L = (Pi - np.asarray(offset, np.float32).reshape(1, 1, 3)) / g
    del Pi
    L -= np.float32(l_ref)
    np.maximum(L, 0.0, out=L)
    np.power(10.0, L / GAMMA_OUT, out=L)
    L -= 1.0
    np.maximum(L, 0.0, out=L)
    return L


def disp(L, ref=99.6):
    w = max(float(np.percentile(L[:, :, 1], ref)), 1e-9)
    return (D.linear_to_srgb(np.clip(L / w, 0, 1))[:, :, ::-1] * 255).astype(np.uint8)


def health(lin, rgb8=None):
    """输入体检：这一帧还剩多少可用信息。"""
    out = {}
    for i, c in enumerate("RGB"):
        ch = lin[:, :, i]
        out[c] = {"unique_T": int(len(np.unique(ch))),
                  "zero_pct": round(float(100.0 * (ch <= 1e-5).mean()), 2),
                  "one_pct": round(float(100.0 * (ch >= 0.999).mean()), 3)}
    Pi = -np.log10(np.clip(lin / zero_scene(lin)[0].reshape(1, 1, 3),
                           10.0 ** -CLIP_PI, 1.0))
    out["pi_capped_pct"] = round(float((Pi >= CLIP_PI - 1e-6).any(axis=2).mean() * 100), 2)
    del Pi
    o = out
    if min(o["R"]["unique_T"], o["G"]["unique_T"], o["B"]["unique_T"]) < 100:
        o["verdict"] = "蓝/某通道被抠死 → 这一帧的信息已经不够，任何方法都只能猜"
    elif o["pi_capped_pct"] > 10:
        o["verdict"] = f"{o['pi_capped_pct']}% 的像素撞密度上限 → 高光/暗部有整片损失"
    else:
        o["verdict"] = "输入尚可"
    return o


# ------------------------------------------------------------------ check

def cmd_check(args):
    files = expand(args.paths)
    if not files:
        print("没找到文件"); return
    print(f"输入体检（{len(files)} 帧）")
    print(f"{'帧':24s}{'R/G/B 唯一值':>24s}{'蓝抠死%':>9s}{'撞上限%':>9s}  判定")
    for f in files:
        lin = load_linear(f)
        h = health(lin)
        print(f"{os.path.basename(f):24s}"
              f"{('/'.join(str(h[c]['unique_T']) for c in 'RGB')):>24s}"
              f"{h['B']['zero_pct']:>9.2f}{h['pi_capped_pct']:>9.2f}  {h['verdict']}")
        del lin

    # 零点一致性
    print("\n零点一致性（判据：片基密度的通道差在同一批里应当是常数）")
    rg, bg = [], []
    for f in files:
        lin = load_linear(f)
        t0, _ = zero_scene(lin)
        Dd = -np.log10(t0)
        rg.append(float(Dd[0] - Dd[1])); bg.append(float(Dd[2] - Dd[1]))
        del lin
    rg, bg = np.array(rg), np.array(bg)
    wr = max(rg.max() - rg.min(), bg.max() - bg.min())
    print(f"  R−G 极差 {rg.max()-rg.min():.4f} D = {(rg.max()-rg.min())/0.30103:.2f} 档")
    print(f"  B−G 极差 {bg.max()-bg.min():.4f} D = {(bg.max()-bg.min())/0.30103:.2f} 档")
    if wr / 0.30103 < 0.35:
        v = "✅ 零点一致 → 可以共用一套标定"
    elif wr / 0.30103 < 0.8:
        v = "⚠️ 有漂移 → 共用标定会带同量级偏色，建议逐帧核对"
    else:
        v = f"❌ 漂移 {wr/0.30103:.2f} 档 → 不能共用一套标定；要么逐帧给零点，要么改用未曝光片基"
    print("  " + v)


# ------------------------------------------------------------------ calibrate

def cmd_calibrate(args):
    src = expand([args.paths])[0] if os.path.isdir(args.paths) else args.paths
    cal, lin, dmin, disp_img, centres, vals = GC.analyse(src, CHART_BBOX)
    out = {"source": os.path.basename(src),
           "gamma": [round(float(v), 6) for v in cal["gamma"]],
           "offset": [round(float(v), 6) for v in cal["offset"]],
           "L_base": round(float(cal["L_base"]), 6),
           "rank1_resid_D": cal["rank1_resid_D"],
           "sigma2_over_sigma1_pct": cal["sigma2_over_sigma1_pct"],
           "grey_patch_lin": cal["grey_patch_lin"],
           "col_ranking": cal["col_ranking"]}
    os.makedirs(os.path.dirname(DEF_CAL), exist_ok=True)
    json.dump(out, open(DEF_CAL, "w"), ensure_ascii=False, indent=1)
    print(f"\n标定已写入 {DEF_CAL}")
    print(f"  γ (R:G:B) = {np.round(cal['gamma'],4)}   ← 这一步是**一次性**的，换型号/换店才需要重做")
    print(f"  秩1 残差 {cal['rank1_resid_D']} D，σ2/σ1 = {cal['sigma2_over_sigma1_pct']}%")
    # 六点中性检验
    g = np.asarray(cal["gamma"]); o = np.asarray(cal["offset"])
    Pi = -np.log10(np.maximum(np.array(cal["grey_patch_lin"]), 1e-7)) - \
         (-np.log10(np.array(cal["dmin"])))
    L = (Pi - o) / g
    dev = np.abs(L - L[:, 1:2]).max(axis=1) / 0.30103 * GAMMA_OUT
    print("  六点中性残差（档）:", np.round(dev, 4).tolist(),
          f" 最大 {dev.max():.4f}")
    if dev.max() > 0.15:
        print("  ⚠️ 残差偏大：这张卡可能拍得不够正/照度不均/没覆盖足够曝光范围")


# ------------------------------------------------------------------ apply

def cmd_apply(args):
    cal = json.load(open(args.cal, encoding="utf-8")) if os.path.exists(args.cal) else None
    if cal is None:
        print(f"找不到标定 {args.cal}，先用 calibrate 生成。这里退回 γ=(1,1,1)")
        gamma, offset, l_ref = [1.0, 1.0, 1.0], [0.0, 0.0, 0.0], 0.0
    else:
        gamma, offset, l_ref = cal["gamma"], cal["offset"], cal["L_base"]
        print(f"标定来源 {cal['source']}  γ={np.round(gamma,4)}")

    files = expand(args.paths)
    os.makedirs(args.out, exist_ok=True)
    print(f"\n{'帧':24s}{'零点来源':>12s}{'绿范围(档)':>11s}{'截黑%':>11s}"
          f"{'中位偏色(档)':>12s}  输出")
    rep = {}
    for f in files:
        lin = load_linear(f)
        if args.zero == "base":
            t0, src_tag = zero_base(lin)
            if t0 is None:
                t0, src_tag = zero_scene(lin)
                src_tag = "scene(退)"
            off, lr = (0.0, 0.0, 0.0), 0.0        # 片基模式下 o 与 L_ref 都归零
        else:
            t0, src_tag = zero_scene(lin)
            off, lr = offset, l_ref
        L = invert_with(lin, t0, gamma, off, lr)
        g = np.maximum(L[:, :, 1], 1e-7)
        # 范围用 99.9 / 1 百分位（0.1 百分位会被"截到 0"的像素毁掉）
        rng = float(np.log2(np.percentile(g, 99.9) / max(np.percentile(g, 1.0), 1e-9)))
        zfrac = float(100.0 * (L[:, :, 1] <= 1e-6).mean())
        lum = L @ np.array([0.2126, 0.7152, 0.0722], np.float32)
        m = (lum >= np.percentile(lum, 35)) & (lum <= np.percentile(lum, 65))
        med = np.median(L[m], axis=0)
        cast = float(np.log2(med.max() / max(med.min(), 1e-9)))
        name = os.path.splitext(os.path.basename(f))[0]
        p = os.path.join(args.out, name + ".jpg")
        cv2.imwrite(p, disp(L), [cv2.IMWRITE_JPEG_QUALITY, 90])
        print(f"{os.path.basename(f):24s}{src_tag:>12s}{rng:>11.2f}{zfrac:>11.2f}"
              f"{cast:>12.3f}  {p}")
        rep[name] = {"zero": src_tag, "range_G_st": round(rng, 2),
                     "zero_floor_pct": round(zfrac, 2), "cast_mid_st": round(cast, 3)}
        del lin, L
    json.dump(rep, open(os.path.join(args.out, "_report.json"), "w"),
              ensure_ascii=False, indent=1)
    print(f"\n注意：中位偏色这一列仍然**只可横向比**（场景不是灰的）。"
          f"要判绝对对错，只能在有已知中性面（片基/色卡/画面里的白墙）的地方看。")


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("check"); p1.add_argument("paths", nargs="+")
    p1.set_defaults(fn=cmd_check)

    p2 = sub.add_parser("calibrate")
    p2.add_argument("paths"); p2.add_argument("--col", default="auto")
    p2.set_defaults(fn=cmd_calibrate)

    p3 = sub.add_parser("apply")
    p3.add_argument("paths", nargs="+")
    p3.add_argument("--zero", choices=["scene", "base"], default="scene")
    p3.add_argument("--cal", default=DEF_CAL)
    p3.add_argument("--out", default=os.path.join(HERE, "out9"))
    p3.set_defaults(fn=cmd_apply)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
