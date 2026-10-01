#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
chart_extract.py —— 从翻拍/扫描的负片里把 SpyderCheckr（4×N 栅格）取出来。

为什么不用现成的色卡识别库：这张色卡是**负片上的**，整幅带橙色色罩、
还有透视角和轻微旋转。通用识别器（如 colour-checker-detection）默认在
正片上工作，喂负片会找不到。所以这里用**先反相、再按亮度投影找分隔条**
的办法，稳且在图上可验证。

流程：
  1) negadoctor 反相 → 得到一张正常的正片（这一步只为了找到栅格）
  2) 在色卡的包围盒里，按行的第 20 百分位找**水平分隔条**（分隔条整行都暗）
  3) 在每个行带里再按列的第 20 百分位找**竖直分隔条** —— 在行带内找，
     自然吸收掉了旋转带来的倾斜
  4) 每个格子取中心 60% 的像素做**迭代修剪中位数**（先取中位数，丢掉
     偏离最远的 40%，再取中位数），把分隔条和噪声排除掉

输出：{'grid': tags, 'rgb': [...]}, 以及一张把采样框画回去的核对图。
"""
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import demask as D


def invert(lin, mode="negadoctor"):
    dmin, sm = D.estimate_base(lin)
    _, dec = D.density_range(sm, dmin)
    dmax = float(np.clip(dec[1], 0.5, 2.5))
    if mode == "negadoctor":
        L = D.method_negadoctor(lin, dmin, dmax)
    else:
        L = D.method_curvekept(lin, dmin, D.density_scales(lin, dmin)[0])
    return L, dmin, dmax


def _groups(mask, min_len=6):
    """把布尔序列里连续 True 的段合并成 [(start, end), ...]。"""
    out, s = [], None
    for i, v in enumerate(mask):
        if v and s is None:
            s = i
        elif not v and s is not None:
            if i - s >= min_len:
                out.append((s, i - 1))
            s = None
    if s is not None and len(mask) - s >= min_len:
        out.append((s, len(mask) - 1))
    return out


def _line_profile(g, axis, klen=61):
    """把"分隔条"从色块里分离出来。

    前两版都失败在同一个地方：直接对灰度做投影，会被**整列/整行色块的
    平均亮度**带偏（比如色卡里有一整列是灰阶，从白走到黑，它的列平均
    亮度正好落在中间，于是任何全局阈值都抓不住分隔条）。

    改用**局部对比**：
      bh = 形态学闭运算(沿垂直方向, 长度 klen) - 原图   → 突出竖直暗条
      同理用水平方向的闭运算突出水平暗条
    闭运算会把相邻色块沿该方向"连起来"，再减去原图，剩下的就只有
    那些比两侧色块暗的细条 —— 与色块本身的绝对亮度无关。
    """
    kern = np.ones((1, klen), np.uint8) if axis == "v" else np.ones((klen, 1), np.uint8)
    closed = cv2.morphologyEx(g.astype(np.uint8), cv2.MORPH_CLOSE, kern)
    bh = closed.astype(np.float64) - g.astype(np.float64)
    return bh


def _peaks(prof, win=26, ratio=0.45):
    """在 1D 剖面上找峰（分组后取加权中心）。"""
    lo, hi = float(np.percentile(prof, 10)), float(prof.max())
    if hi <= lo:
        return []
    thr = lo + (hi - lo) * ratio
    idx = np.where(prof >= thr)[0]
    if idx.size == 0:
        return []
    groups, cur = [], [idx[0]]
    for i in idx[1:]:
        if i - cur[-1] <= win:
            cur.append(i)
        else:
            groups.append(cur); cur = [i]
    groups.append(cur)
    out = []
    for gp in groups:
        w = prof[gp] - thr
        out.append(int(round(float((np.array(gp) * w).sum() / max(w.sum(), 1e-9)))))
    return out


def detect(disp, bbox, rows=6, cols=4, klen=91):
    """色卡是**规则点阵**，所以最稳的做法不是逐条找分隔条，而是：
      ① 找到最上和最下那条横边、最左和最右那条竖边（它们对比最强，最不容易漏）；
      ② 在这四条边之间**等分**出 rows/cols 个格子。
    这样只需要 4 个可靠的读数，而不是 7+5 个 —— 前面两版的失败都源于
    试图把每一条分隔条都独立找出来。

    竖线是**逐行带**单独拟合的：色卡在翻拍里有 2~4° 倾斜，分带拟合
    天然吸收掉它，不需要显式做透视校正。
    """
    x0, x1, y0, y1 = bbox
    g = cv2.cvtColor(disp[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY).astype(np.float64)

    bh_v = _line_profile(g, "v", klen)      # 竖条（水平方向闭运算）
    bh_h = _line_profile(g, "h", klen)      # 横条（竖直方向闭运算）

    hpk = _peaks(np.median(bh_h, axis=1), win=25, ratio=0.30)
    if len(hpk) < 2:
        raise RuntimeError(f"没找到横边（{len(hpk)} 条）")
    top, bot = float(hpk[0]), float(hpk[-1])
    hlines = [top + (bot - top) * i / rows for i in range(rows + 1)]

    vseps, centres = [], []
    for ri in range(rows):
        a, b = int(round(hlines[ri])), int(round(hlines[ri + 1]))
        inner = slice(max(0, a + 3), min(bh_v.shape[0], b - 2))
        if inner.stop - inner.start < 12:
            continue
        pk = _peaks(np.median(bh_v[inner, :], axis=0), win=22, ratio=0.30)
        if len(pk) < 2:
            vseps.append([]); continue
        left, right = float(pk[0]), float(pk[-1])
        vlines = [left + (right - left) * j / cols for j in range(cols + 1)]
        vseps.append([int(round(v)) + x0 for v in vlines])
        for ci in range(cols):
            c, d = int(round(vlines[ci])), int(round(vlines[ci + 1]))
            centres.append({"row": ri + 1, "col": ci + 1,
                            "cx": x0 + (c + d) // 2, "cy": y0 + (a + b) // 2,
                            "pw": d - c, "ph": b - a,
                            "box": (x0 + c, y0 + a, x0 + d, y0 + b)})
    return [y0 + int(round(v)) for v in hlines], vseps, centres


def sample(disp, centres, shrink=0.30):
    """每个格子取中心 (1-2*shrink) 的部分，做迭代修剪中位数。"""
    out = []
    for p in centres:
        cx, cy, pw, ph = p["cx"], p["cy"], p["pw"], p["ph"]
        hw, hh = int(pw * (0.5 - shrink)), int(ph * (0.5 - shrink))
        patch = disp[cy - hh:cy + hh + 1, cx - hw:cx + hw + 1].reshape(-1, 3).astype(np.float64)
        v = patch
        for _ in range(3):
            med = np.median(v, axis=0)
            d = np.linalg.norm(v - med, axis=1)
            keep = d <= np.percentile(d, 60)
            if keep.sum() < 16:
                break
            v = v[keep]
        out.append({"row": p["row"], "col": p["col"], "cx": cx, "cy": cy,
                    "rgb": [round(float(x), 2) for x in np.median(v, axis=0)],
                    "n_px": int(v.shape[0])})
    return out


def overlay(disp, centres, path):
    o = disp.copy()
    for p in centres:
        x0, y0, x1, y1 = p["box"]
        hw, hh = int(p["pw"] * 0.20), int(p["ph"] * 0.20)
        cv2.rectangle(o, (x0 + hw, y0 + hh), (x1 - hw, y1 - hh), (0, 255, 0), 2)
        cv2.circle(o, (p["cx"], p["cy"]), 3, (0, 0, 255), -1)
    cv2.imwrite(path, o)


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else \
        "./gold200/000364980009.TIF"
    im = cv2.imread(src)
    lin = D.srgb_to_linear(im[:, :, ::-1].astype(np.float32) / 255.0)
    L, dmin, dmax = invert(lin)
    disp = (D.linear_to_srgb(np.clip(L / max(float(np.percentile(L[:, :, 1], 99.9)), 1e-9), 0, 1))
            [:, :, ::-1] * 255).astype(np.uint8)
    print(f"{os.path.basename(src)}  dmin(T)={np.round(dmin,4)}  d_max={dmax:.3f}")
    for tag, bbox in (("左页", (1615, 2265, 1240, 2190)), ("右页", (2395, 3010, 1240, 2190))):
        try:
            hsep, vseps, cen = detect(disp, bbox)
        except RuntimeError as e:
            print(f"  {tag}: {e}")
            continue
        print(f"  {tag}: 横线 y = {hsep}")
        print(f"        每行竖线 {vseps}\n        格子 {len(cen)}")
        for v in cen:
            print(f"        r{v['row']}c{v['col']}  ({v['cx']},{v['cy']})  {v['pw']}x{v['ph']}")
        sub = disp[bbox[2]:bbox[3], bbox[0]:bbox[1]].copy()
        o = sub.copy()
        for v in cen:
            bx0, by0, bx1, by1 = v["box"]
            hw, hh = int(v["pw"]*0.20), int(v["ph"]*0.20)
            cv2.rectangle(o, (bx0-bbox[0]+hw, by0-bbox[2]+hh), (bx1-bbox[0]-hw, by1-bbox[2]-hh), (0,255,0), 2)
        cv2.imwrite(f"inspect2/chk_{tag}.png", o)
