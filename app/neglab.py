#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NegLab —— 去色罩工作台（macOS 桌面应用）

把「先解决参数、再解决方法」这条流程做成一个能点的东西。
界面刻意压到三步：**打开 → 定零点 → 解 γ**，然后导出。

────────────────────────────────────────────────────────
核心只有三行数学（全部在 invert() 里）：

    Pi_c  = −log10( clip(T_c / T0_c) )        负片相对「零点」的密度
    L_c   = (Pi_c − o_c) / γ_c                逐通道曝光坐标
    out_c = 10 ** ((L_c − L_ref) / 0.6) − 1    反相

三个参数各自的来源与「多久定一次」：

  T0  零点     **每帧都要定**。· 点片基（最准）· 画面最亮 0.05%（免费但会被场景带偏）
  γ   斜率     **一次性** —— 管一个「胶片型号 × 扫描/翻拍链路」。换型号/换店/换光源才重做。
               这条不是自创：RawTherapee 的 Film Negative 用的就是同一个量
               （Red ratio = γ_R/γ_G，Blue ratio = γ_B/γ_G），
               它的官方文档也写明「每卷点一次，可拷给同卷其它照片」。
  o   偏移     和 γ 一起从「点中性灰」解出来。

标定：在负片上点若干块「你确定是中性的灰」（≥2 块，亮度要拉开）。
**不需要知道这些灰的绝对亮度** —— 只要它们中性。数学上是秩 1 分解：

    Pi_c(k) = o_c + γ_c · L_k     →  N×3 矩阵去掉列均值后应当秩 1
    σ2/σ1（第二奇异值占第一的比例）= 「这批点够不够中性」的读数

⚠️ 两个踩过的坑，写在代码里免得再犯：
  1. 三通道的 L **各自保留**，绝不能取中位数 —— 取了输出就是一张灰图。
  2. 跨帧搬运标定时，偏移 o 与 L_ref **是常数，不要做任何「平移」** —— 见 _params()。
"""

import json
import os
import subprocess
import sys
import traceback

import numpy as np

from PySide6.QtCore import Qt, QPoint, QTimer, Signal
from PySide6.QtGui import QImage, QPixmap, QPainter, QPen, QColor, QAction, QKeySequence
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QLabel, QPushButton, QSlider,
    QFileDialog, QHBoxLayout, QVBoxLayout, QGroupBox, QPlainTextEdit, QSplitter,
    QMessageBox, QRadioButton, QButtonGroup, QScrollArea, QFrame, QStackedWidget)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import demask as D

APPNAME = "NegLab"
VERSION = "2.0"
GAMMA_OUT = 0.6

# 密度上限。挡住 8-bit 抠死产生的假动态范围。
# ⚠️ 自检发现：取 1.8 时很密的区域会被**逐通道分别**削掉，平白制造最多 1.08 档假偏色；
#    取 2.5 时该值为 0。所以用 2.5。
PI_CLIP = 2.5
PROXY_MAX = 1600

RAW_EXT = (".arw", ".cr3", ".cr2", ".nef", ".nrw", ".dng", ".raf", ".orf",
           ".rw2", ".pef", ".srw", ".dcr", ".kdc", ".mrw", ".x3f")

C_BG, C_CARD, C_LINE = "#f6f6f7", "#ffffff", "#e3e3e6"
C_INK, C_MUT, C_ACC = "#1d1d1f", "#86868b", "#0071e3"
C_OK, C_WARN = "#1d8a4e", "#c0392b"


# ═══════════════════════════════════════════════════ 数学

def fit_gamma(samples_lin, t0):
    """秩 1 分解解 γ。samples_lin: N×3 负片线性透过率；t0: 同一套零点。

    ⚠️ Pi 必须用同一个 t0 —— 换零点要重解（偏移 o 是「相对某个零点」定义的）。
    """
    T = np.maximum(np.asarray(samples_lin, np.float64) /
                   np.asarray(t0, np.float64), 1e-7)
    if T.shape[0] < 2:
        raise RuntimeError("至少要点两块灰")
    Pi = -np.log10(T)
    C = Pi - Pi.mean(axis=0, keepdims=True)
    _, s, vt = np.linalg.svd(C, full_matrices=False)
    g = vt[0]
    if g[1] < 0:
        g = -g
    L = C[:, 1] / max(g[1], 1e-12)
    resid = C - np.outer(L, g)
    return (g / g[1], Pi.mean(axis=0), float(s[1] / max(s[0], 1e-12)),
            float(np.abs(resid).max()), L)


def invert(lin, t0, gamma, offset, l_ref, exposure=1.0, black=0.0, clip=PI_CLIP):
    """三行数学。lin 是线性透过率（float32，0..1）。"""
    x = np.clip(lin / np.asarray(t0, np.float32).reshape(1, 1, 3), 10.0 ** (-clip), 1.0)
    Pi = -np.log10(np.maximum(x, 1e-7))
    del x
    L = (Pi - np.asarray(offset, np.float32).reshape(1, 1, 3)) / \
        np.asarray(gamma, np.float32).reshape(1, 1, 3)
    del Pi
    if l_ref:
        L -= np.float32(l_ref)
    np.maximum(L, 0.0, out=L)
    np.power(10.0, L / GAMMA_OUT, out=L)
    L -= 1.0
    np.maximum(L, 0.0, out=L)
    if black > 0:
        L -= np.float32(black)
        np.maximum(L, 0.0, out=L)
    if exposure != 1.0:
        L *= np.float32(exposure)
    return L


def to_display(L, pct=99.5):
    w = max(float(np.percentile(L[:, :, 1], pct)), 1e-7)
    return np.ascontiguousarray(
        (D.linear_to_srgb(np.clip(L / w, 0, 1))[:, :, ::-1] * 255).astype(np.uint8))


def health(lin, t0):
    o = {}
    for i, c in enumerate("RGB"):
        ch = lin[:, :, i]
        o[c] = {"unique": int(len(np.unique(ch))),
                "crush": round(float(100.0 * (ch <= 1e-5).mean()), 2),
                "sat": round(float(100.0 * (ch >= 0.999).mean()), 3)}
    Pi = -np.log10(np.clip(lin / np.asarray(t0, np.float32).reshape(1, 1, 3),
                           10.0 ** -PI_CLIP, 1.0))
    o["capped"] = round(float((Pi >= PI_CLIP - 1e-6).any(axis=2).mean() * 100), 2)
    u = min(o[c]["unique"] for c in "RGB")
    if u < 100:
        o["verdict"] = f"某通道唯一值只有 {u} —— 已被量化抠死，任何算法都只能猜"
        o["level"] = "bad"
    elif o["capped"] > 10:
        o["verdict"] = f"{o['capped']}% 的像素撞到密度上限 {PI_CLIP} —— 高光或暗部整片损失"
        o["level"] = "warn"
    else:
        o["verdict"] = "输入尚可"
        o["level"] = "ok"
    return o


# ═══════════════════════════════════════════════════ 图像 IO

def raw2linear_path():
    for p in (os.path.join(HERE, "raw2linear"),
              os.path.join(HERE, "tools", "raw2linear"),
              os.path.abspath(os.path.join(HERE, "..", "tools", "raw2linear"))):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def convert_raw(path, outdir=None, exposure=0.0, wb=None):
    """相机 raw → 16-bit 线性 TIFF（用随包的 raw2linear，走 macOS 自带 Core Image）。"""
    exe = raw2linear_path()
    if exe is None:
        raise RuntimeError(
            "没找到 raw2linear 工具。\n\n"
            "选择一：在仓库里跑 tools/build_tools.sh 编一个；\n"
            "选择二：用 RawTherapee / darktable / Lightroom 把 raw 导出成 16-bit 线性 TIFF。")
    outdir = outdir or os.path.join(os.path.expanduser("~"), "Pictures", "NegLab_linear")
    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0] + "_linear.tif")
    cmd = [exe, path, out]
    if exposure:
        cmd += ["--exposure", f"{exposure:g}"]
    if wb:
        cmd += ["--wb", f"{wb:g}"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or "转换失败").strip())
    return out, (r.stderr or "").strip()


def read_image(path):
    """读负片：16-bit 线性 TIFF 或 8-bit sRGB。相机 raw 会自动先转。"""
    import cv2
    if os.path.splitext(path)[1].lower() in RAW_EXT:
        path, _ = convert_raw(path)
    raw = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if raw is None:
        raise RuntimeError("读不了这个文件。若是 raw，请先用 RawTherapee / darktable "
                           "导成 16-bit 线性 TIFF。")
    if raw.ndim == 2:
        raw = np.repeat(raw[:, :, None], 3, 2)
    bgr = np.ascontiguousarray(raw[:, :, :3])
    if bgr.dtype == np.uint16:
        lin = bgr[:, :, ::-1].astype(np.float32) / 65535.0
        enc = "16-bit → 视为线性"
    elif bgr.dtype == np.uint8:
        lin = D.srgb_to_linear(bgr[:, :, ::-1].astype(np.float32) / 255.0)
        enc = "8-bit → 反解 sRGB 得线性"
    else:
        lin = np.clip(bgr[:, :, ::-1].astype(np.float32), 0, 1)
        enc = str(bgr.dtype)
    return lin, {"name": os.path.basename(path), "wh": (lin.shape[1], lin.shape[0]),
                 "encoding": enc, "bytes": os.path.getsize(path)}


# ═══════════════════════════════════════════════════ 视图

class View(QLabel):
    clicked = Signal(int, int)
    dropped = Signal(str)

    def __init__(self):
        super().__init__()
        self.setAcceptDrops(True)
        self.setMinimumSize(620, 460)
        self.setAlignment(Qt.AlignCenter)
        self.setStyleSheet("background:#2b2b2e;color:#8a8a8e;border-radius:10px")
        self.setText("把负片拖到这里\n或按 ⌘O 打开")
        self._pix = None
        self._scale = 1.0
        self._marks = []
        self._mode = "none"

    def set_image(self, bgr8):
        h, w = bgr8.shape[:2]
        qi = QImage(bgr8.data, w, h, 3 * w, QImage.Format_BGR888)
        self._pix = QPixmap.fromImage(qi.copy())
        self.setText("")
        self.update()

    def set_mode(self, m):
        self._mode = m
        self.setCursor(Qt.CrossCursor if m != "none" else Qt.ArrowCursor)

    def set_marks(self, marks):
        self._marks = marks
        self.update()

    def _geom(self):
        if self._pix is None:
            return None
        pw, ph = self._pix.width(), self._pix.height()
        s = min((self.width() - 4) / pw, (self.height() - 4) / ph, 1.0)
        self._scale = s
        dw, dh = int(pw * s), int(ph * s)
        return ((self.width() - dw) // 2, (self.height() - dh) // 2, dw, dh)

    def paintEvent(self, ev):
        super().paintEvent(ev)
        g = self._geom()
        if g is None:
            return
        x, y, dw, dh = g
        p = QPainter(self)
        p.setRenderHint(QPainter.SmoothPixmapTransform, True)
        p.drawPixmap(x, y, dw, dh, self._pix)
        r = 9
        for (mx, my, kind) in self._marks:
            px, py = x + mx * self._scale, y + my * self._scale
            col = QColor(C_OK) if kind == "grey" else QColor("#ff9f0a")
            p.setPen(QPen(col, 2.2))
            p.setBrush(QColor(255, 255, 255, 60))
            p.drawEllipse(QPoint(int(px), int(py)), r, r)
            p.drawLine(int(px) - r - 5, int(py), int(px) + r + 5, int(py))
            p.drawLine(int(px), int(py) - r - 5, int(px), int(py) + r + 5)

    def _to_img(self, pos):
        g = self._geom()
        if g is None:
            return None
        x, y, dw, dh = g
        if not (x <= pos.x() <= x + dw and y <= pos.y() <= y + dh):
            return None
        return (int((pos.x() - x) / self._scale), int((pos.y() - y) / self._scale))

    def mousePressEvent(self, ev):
        if self._mode == "none" or self._pix is None:
            return
        p = self._to_img(ev.position().toPoint())
        if p:
            self.clicked.emit(*p)

    def dragEnterEvent(self, ev):
        if ev.mimeData().hasUrls():
            ev.acceptProposedAction()

    def dropEvent(self, ev):
        for u in ev.mimeData().urls():
            p = u.toLocalFile()
            if p and os.path.isfile(p):
                self.dropped.emit(p)
                break


# ═══════════════════════════════════════════════════ 小组件

def hint(text, color=C_MUT, size=12):
    lb = QLabel(text)
    lb.setWordWrap(True)
    lb.setStyleSheet(f"color:{color};font-size:{size}px")
    return lb


def card(title, step=None):
    g = QGroupBox(title if step is None else f"{step}　{title}")
    g.setStyleSheet(f"""
      QGroupBox {{background:{C_CARD};border:1px solid {C_LINE};border-radius:10px;
                  margin-top:10px;padding:14px 14px 10px 14px;
                  font-weight:600;color:{C_INK};font-size:13px}}
      QGroupBox::title {{subcontrol-origin:margin;left:12px;padding:0 5px;}}
      QGroupBox QLabel {{font-weight:400;}}
    """)
    return g


def primary(t):
    b = QPushButton(t)
    b.setStyleSheet(f"""
      QPushButton {{background:{C_ACC};color:#fff;border:none;border-radius:8px;
        padding:8px 14px;font-size:13px;font-weight:600}}
      QPushButton:hover {{background:#0077ed}}
      QPushButton:pressed {{background:#0066cc}}
      QPushButton:disabled {{background:#d2d2d7;color:#fff}}
      QPushButton:checked {{background:#1d8a4e}}
    """)
    b.setMinimumHeight(33)
    return b


def plain(t):
    b = QPushButton(t)
    b.setStyleSheet(f"""
      QPushButton {{background:{C_BG};color:{C_INK};border:1px solid {C_LINE};
        border-radius:8px;padding:7px 12px;font-size:12.5px}}
      QPushButton:hover {{background:#ebebee}}
      QPushButton:checked {{background:#1d8a4e;color:#fff;border-color:#1d8a4e}}
      QPushButton:disabled {{color:#c7c7cc}}
    """)
    b.setMinimumHeight(31)
    return b


# ═══════════════════════════════════════════════════ 主窗口

class Win(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{APPNAME} · 去色罩工作台")
        self.resize(1280, 840)
        self.setMinimumSize(1020, 700)

        self.lin = None
        self.proxy = None
        self.info = {}
        self.scale_xy = (1.0, 1.0)
        self.pts = []
        self.base_pt = None
        self.cal_t0 = None
        self.offset = [0.0, 0.0, 0.0]
        self.l_ref = 0.0
        self._pending = False
        self._last_dir = os.path.expanduser("~/Pictures")

        top = QFrame()
        top.setStyleSheet(f"background:{C_CARD};border-bottom:1px solid {C_LINE}")
        tl = QHBoxLayout(top)
        tl.setContentsMargins(18, 11, 18, 11)
        tl.setSpacing(8)
        self.step_labels = []
        for i, s in enumerate(("打开负片", "定零点", "解 γ", "导出")):
            lb = QLabel(f"{i+1}　{s}")
            lb.setStyleSheet(f"color:{C_MUT};font-size:12.5px;padding:4px 11px;border-radius:7px")
            tl.addWidget(lb)
            self.step_labels.append(lb)
        tl.addStretch(1)
        b = plain("使用说明")
        b.clicked.connect(lambda: self.stack.setCurrentIndex(0))
        tl.addWidget(b)
        b = primary("打开…  ⌘O")
        b.clicked.connect(self.open_file)
        tl.addWidget(b)

        self.view = View()
        self.view.clicked.connect(self.on_click)
        self.view.dropped.connect(self.load_path)
        left = QWidget()
        lv = QVBoxLayout(left)
        lv.setContentsMargins(14, 14, 7, 14)
        lv.setSpacing(9)
        lv.addWidget(self.view, 1)
        self.status = hint("", C_MUT, 12)
        lv.addWidget(self.status)

        panel = QWidget()
        pv = QVBoxLayout(panel)
        pv.setContentsMargins(14, 6, 14, 18)
        pv.setSpacing(0)
        self._build_panel(pv)
        sc = QScrollArea()
        sc.setWidget(panel)
        sc.setWidgetResizable(True)
        sc.setFrameShape(QFrame.NoFrame)
        sc.setStyleSheet(f"background:{C_BG}")
        sc.setMinimumWidth(400)
        sc.setMaximumWidth(468)
        right = QWidget()
        rv = QVBoxLayout(right)
        rv.setContentsMargins(7, 14, 14, 14)
        rv.addWidget(sc)

        self.splitter = QSplitter(Qt.Horizontal)
        self.splitter.addWidget(left)
        self.splitter.addWidget(right)
        self.splitter.setStretchFactor(0, 1)
        self.splitter.setStretchFactor(1, 0)

        self.guide = self._build_guide()
        self.stack = QStackedWidget()
        self.stack.addWidget(self.guide)
        self.stack.addWidget(self.splitter)

        root = QWidget()
        rl = QVBoxLayout(root)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.setSpacing(0)
        rl.addWidget(top)
        rl.addWidget(self.stack, 1)
        self.setCentralWidget(root)

        for name, seq, fn in (("打开", QKeySequence.Open, self.open_file),
                              ("导出", "Ctrl+E", lambda: self.export("tif")),
                              ("撤销上一个点", "Ctrl+Z", self.undo_point),
                              ("退出点选", Qt.Key_Escape, self.exit_mode)):
            a = QAction(name, self)
            a.setShortcut(seq)
            a.triggered.connect(fn)
            self.addAction(a)

        self.setStyleSheet(f"""
          QMainWindow,QWidget{{background:{C_BG};color:{C_INK};
            font-family:-apple-system,"SF Pro Text","PingFang SC",sans-serif;font-size:13px}}
          QPlainTextEdit{{background:{C_CARD};border:1px solid {C_LINE};border-radius:8px;
            font-family:ui-monospace,Menlo,monospace;font-size:11px;color:{C_INK};padding:9px}}
          QRadioButton{{font-size:12.5px;color:{C_INK};padding:3px 0}}
          QScrollBar:vertical{{background:transparent;width:9px;margin:0}}
          QScrollBar::handle:vertical{{background:#cfcfd4;border-radius:4px;min-height:32px}}
          QScrollBar::add-line,QScrollBar::sub-line{{height:0}}
          QScrollBar::add-page,QScrollBar::sub-page{{background:transparent}}
        """)
        self.stack.setCurrentIndex(0)
        self._sync_steps()

    # ------------------------------------------------- 引导

    def _build_guide(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(72, 44, 72, 44)
        v.setSpacing(14)

        t = QLabel(APPNAME)
        t.setStyleSheet(f"font-size:32px;font-weight:700;color:{C_INK};letter-spacing:-.6px")
        v.addWidget(t)
        v.addWidget(hint("把彩色负片扫描件反相成中性、线性的正片。只做一件事："
                         "<b>把「参数」从猜变成可测量</b>。", C_MUT, 13.5))
        v.addSpacing(10)

        for title, body in (
            ("① 打开一张负片",
             "16-bit 线性 TIFF 最好；8-bit 店扫件也能读，但会有损失（体检会告诉你损失多少）。"
             "相机 raw（ARW / CR3 / NEF / DNG…）会自动调用随包工具转成 16-bit 线性 TIFF。"),
            ("② 定零点（每帧都要）",
             "「零曝光」落在密度轴的哪里。画面里有<b>未曝光片基</b>（齿孔、帧边透明条）就点它 —— "
             "最准，而且帧帧独立。没有片基就先用「画面最亮 0.05%」，"
             "但要记得它会被这帧最亮的东西的颜色带偏。"),
            ("③ 解 γ（一次性）",
             "在负片上点若干块<b>你确定是中性的灰</b>（≥2 块，亮度要拉开）。"
             "<b>不需要知道它们的绝对亮度</b>，只要它们中性。软件会告诉你「这批点够不够中性」。"
             "这个值管一个「胶片型号 × 扫描/翻拍链路」—— 换型号、换店、换光源才需要重做。"),
            ("④ 看读数、导出",
             "唯一的验收标准是「你点的那些灰，反相之后还剩多少偏色」。"
             "导出 16-bit 线性 TIFF 进 DaVinci Resolve / Lightroom 继续分级。"),
        ):
            row = QHBoxLayout()
            lb = QLabel(title)
            lb.setFixedWidth(158)
            lb.setAlignment(Qt.AlignTop | Qt.AlignLeft)
            lb.setStyleSheet(f"font-size:14px;font-weight:600;color:{C_INK}")
            row.addWidget(lb)
            row.addWidget(hint(body, C_MUT, 12.5), 1)
            v.addLayout(row)

        v.addSpacing(16)
        ln = QFrame()
        ln.setFrameShape(QFrame.HLine)
        ln.setStyleSheet(f"color:{C_LINE}")
        v.addWidget(ln)
        v.addWidget(hint(
            "<b>为什么不直接用现成软件？</b>negadoctor / DiVERE / SpektraLab 都把 γ 当成内置常数，"
            "或让人手搓滑杆；而决定成败的这个参数，在你手上的文件里是<b>可以测</b>的。"
            "实测：从画面猜斜率，红通道 0.738 / 蓝 1.770；从灰阶卡读出来是 0.933 / 1.626 —— "
            "差 0.34 档，而所有方法之间的差异只有 0.1~0.3 档。", C_MUT, 12))
        v.addStretch(1)

        row = QHBoxLayout()
        b = primary("开始使用")
        b.setMinimumWidth(132)
        b.clicked.connect(lambda: self.stack.setCurrentIndex(1))
        row.addWidget(b)
        b = plain("灰阶卡怎么拍？")
        b.clicked.connect(self.show_card_help)
        row.addWidget(b)
        row.addStretch(1)
        v.addLayout(row)
        return w

    def show_card_help(self):
        QMessageBox.information(
            self, "灰阶卡怎么拍",
            "最省的做法：每卷开头占用 1~2 格，拍一段灰阶阶梯（≥6 级，亮度要拉开）。\n\n"
            "现成的卡更好：Datacolor SpyderCheckr（48 格，自带多条中性列）；\n"
            "ColorChecker Classic（24 格，底部有一整行 6 级灰阶）也够用。\n\n"
            "三个硬要求：\n"
            "① 和画面同卷、同光、同一次扫描；\n"
            "② 卡要完整出现在画面里（店把画幅裁到 36×24mm 就会切掉）；\n"
            "③ 级数要覆盖 片基 → 接近 Dmax（只拍一块 18% 灰卡能钉偏移、钉不了斜率）。\n\n"
            "换光源（RGB 窄谱 ↔ 宽带白光）等于换链路 —— γ 要重标一次。")

    # ------------------------------------------------- 面板

    def _build_panel(self, pv):
        g0 = card("当前文件")
        l0 = QVBoxLayout(g0)
        self.lbl_file = hint("（还没打开）", C_MUT, 12)
        l0.addWidget(self.lbl_file)
        self.lbl_health = hint("", C_MUT, 11.5)
        l0.addWidget(self.lbl_health)
        pv.addWidget(g0)

        g1 = card("零点 T0", "②")
        l1 = QVBoxLayout(g1)
        l1.addWidget(hint("每帧都要定。有片基就点片基。", C_MUT, 11.5))
        self.rb_scene = QRadioButton("画面最亮 0.05%（免费；会被这帧最亮处的颜色带偏）")
        self.rb_base = QRadioButton("手动点选（点一下片基／最亮的中性处）")
        self.rb_scene.setChecked(True)
        bg = QButtonGroup(self)
        bg.addButton(self.rb_scene)
        bg.addButton(self.rb_base)
        self.rb_scene.toggled.connect(lambda _: (self._sync_steps(), self.schedule()))
        self.rb_base.toggled.connect(lambda _: (self._sync_steps(), self.schedule()))
        l1.addWidget(self.rb_scene)
        l1.addWidget(self.rb_base)
        row = QHBoxLayout()
        self.b_base = plain("点片基")
        self.b_base.setCheckable(True)
        self.b_base.clicked.connect(lambda: self.set_mode("base" if self.b_base.isChecked() else "none"))
        row.addWidget(self.b_base)
        b = plain("清除")
        b.clicked.connect(self.clear_base)
        row.addWidget(b)
        l1.addLayout(row)
        self.lbl_t0 = hint("", C_MUT, 11)
        l1.addWidget(self.lbl_t0)
        pv.addWidget(g1)

        g2 = card("γ 标定", "③")
        l2 = QVBoxLayout(g2)
        l2.addWidget(hint("在负片上点中性灰（≥2 块，亮度拉开）。不需要知道它们的绝对亮度。",
                          C_MUT, 11.5))
        row = QHBoxLayout()
        self.b_grey = plain("点中性灰")
        self.b_grey.setCheckable(True)
        self.b_grey.clicked.connect(lambda: self.set_mode("grey" if self.b_grey.isChecked() else "none"))
        row.addWidget(self.b_grey)
        self.b_fit = primary("解算 γ")
        self.b_fit.setEnabled(False)
        self.b_fit.clicked.connect(self.do_fit)
        row.addWidget(self.b_fit)
        b = plain("清除")
        b.clicked.connect(self.clear_grey)
        row.addWidget(b)
        l2.addLayout(row)
        self.lbl_fit = hint("γ = 1.000 : 1 : 1.000　（未标定）", C_INK, 12)
        l2.addWidget(self.lbl_fit)
        self.sl_gR, self.lb_gR = self._slider(l2, "γ_R / γ_G", 0.50, 1.80, 1.00, 0.002)
        self.sl_gB, self.lb_gB = self._slider(l2, "γ_B / γ_G", 0.50, 2.60, 1.00, 0.002)
        row = QHBoxLayout()
        b = plain("存标定…")
        b.clicked.connect(self.save_cal)
        row.addWidget(b)
        b = plain("载标定…")
        b.clicked.connect(self.load_cal)
        row.addWidget(b)
        l2.addLayout(row)
        pv.addWidget(g2)

        g3 = card("显示微调（不改标定）", "④")
        l3 = QVBoxLayout(g3)
        self.sl_exp, self.lb_exp = self._slider(l3, "曝光", -2.0, 2.0, 0.0, 0.01, "档", signed=True)
        self.sl_blk, self.lb_blk = self._slider(l3, "黑点", 0.0, 0.06, 0.0, 0.0005)
        pv.addWidget(g3)

        g4 = card("读数（验收）")
        l4 = QVBoxLayout(g4)
        self.txt = QPlainTextEdit()
        self.txt.setReadOnly(True)
        self.txt.setMinimumHeight(220)
        self.txt.setPlainText("打开一张负片后，这里会显示：\n"
                              "· 输入体检（这一帧还剩多少可用信息）\n"
                              "· 零点、γ、偏移\n"
                              "· ★ 验收：你点的那些灰反相后还剩多少偏色")
        l4.addWidget(self.txt)
        pv.addWidget(g4)

        g5 = card("导出全分辨率")
        l5 = QVBoxLayout(g5)
        row = QHBoxLayout()
        b = primary("16-bit 线性 TIFF　⌘E")
        b.clicked.connect(lambda: self.export("tif"))
        row.addWidget(b)
        b = plain("8-bit JPEG")
        b.clicked.connect(lambda: self.export("jpg"))
        row.addWidget(b)
        l5.addLayout(row)
        l5.addWidget(hint("TIFF 是线性母版，进 Resolve / Lightroom 继续分级。", C_MUT, 11))
        pv.addWidget(g5)
        pv.addStretch(1)

    def _slider(self, parent, label, lo, hi, val, step, unit="", signed=False):
        row = QHBoxLayout()
        lb = QLabel(label)
        lb.setMinimumWidth(76)
        lb.setStyleSheet(f"font-size:12px;color:{C_INK}")
        row.addWidget(lb)
        s = QSlider(Qt.Horizontal)
        s.setRange(0, int(round((hi - lo) / step)))
        s.setValue(int(round((val - lo) / step)))
        row.addWidget(s, 1)
        v = QLabel()
        v.setMinimumWidth(58)
        v.setStyleSheet(f"font-family:Menlo;font-size:11px;color:{C_INK}")
        row.addWidget(v)
        parent.addLayout(row)
        s._lo, s._step, s._signed, s._unit = lo, step, signed, unit

        def upd(_=None):
            nv = s._lo + s.value() * s._step
            v.setText((f"{nv:+.3f}" if s._signed else f"{nv:.3f}") + s._unit)
            self.schedule()
        s.valueChanged.connect(upd)
        upd()
        return s, v

    def slv(self, s):
        return s._lo + s.value() * s._step

    def _sync_steps(self):
        done = [self.lin is not None, self.lin is not None,
                self.cal_t0 is not None, False]
        for i, lb in enumerate(self.step_labels):
            if done[i]:
                lb.setStyleSheet(f"color:#fff;background:{C_OK};font-size:12.5px;"
                                 f"padding:4px 11px;border-radius:7px")
            else:
                lb.setStyleSheet(f"color:{C_MUT};font-size:12.5px;padding:4px 11px;border-radius:7px")

    # ------------------------------------------------- 交互

    def open_file(self):
        p, _ = QFileDialog.getOpenFileName(
            self, "打开负片", self._last_dir,
            "负片扫描件 (*.tif *.tiff *.png *.jpg *.jpeg);;"
            "相机 raw（自动转 16-bit 线性 TIFF） "
            "(*.arw *.cr3 *.cr2 *.nef *.nrw *.dng *.raf *.orf *.rw2);;所有文件 (*)")
        if p:
            self.load_path(p)

    def load_path(self, path):
        try:
            QApplication.setOverrideCursor(Qt.WaitCursor)
            lin, info = read_image(path)
        except Exception as e:
            QApplication.restoreOverrideCursor()
            QMessageBox.critical(self, "打不开", str(e))
            return
        QApplication.restoreOverrideCursor()
        self._last_dir = os.path.dirname(path)
        self.lin, self.info = lin, info
        h, w = lin.shape[:2]
        s = min(1.0, PROXY_MAX / max(h, w))
        if s < 1.0:
            import cv2
            self.proxy = np.ascontiguousarray(cv2.resize(
                lin, (max(1, int(w * s)), max(1, int(h * s))), interpolation=cv2.INTER_AREA))
        else:
            self.proxy = lin
        self.scale_xy = (self.proxy.shape[1] / w, self.proxy.shape[0] / h)
        self.pts, self.base_pt, self.cal_t0 = [], None, None
        self.offset, self.l_ref = [0.0, 0.0, 0.0], 0.0
        self.rb_scene.setChecked(True)
        self.b_fit.setEnabled(False)
        self.lbl_file.setText(f"<b>{info['name']}</b><br>"
                              f"{info['wh'][0]}×{info['wh'][1]}　{info['encoding']}　"
                              f"{info['bytes']/1e6:.1f} MB")
        self.stack.setCurrentIndex(1)
        self.setStatus("② 先定零点：画面里有未曝光片基就点「点片基」，没有就先用自动。")
        self.schedule()

    def set_mode(self, m):
        self.view.set_mode(m)
        self.b_grey.setChecked(m == "grey")
        self.b_base.setChecked(m == "base")
        self.setStatus({"grey": "点负片上你确定是中性的灰块（多点几块、亮度拉开，点在色块中央）",
                        "base": "点负片上最亮的未曝光处／片基",
                        "none": ""}.get(m, ""))

    def exit_mode(self):
        self.set_mode("none")

    def undo_point(self):
        if self.pts:
            self.pts.pop()
            self.sync_marks()
            self.b_fit.setEnabled(len(self.pts) >= 2)
            self.schedule()

    def setStatus(self, t):
        self.status.setText(t or "")

    def _sample(self, x, y, r=7):
        sx, sy = self.scale_xy
        X, Y = int(round(x / sx)), int(round(y / sy))
        h, w = self.lin.shape[:2]
        X, Y = min(max(X, r), w - 1 - r), min(max(Y, r), h - 1 - r)
        v = self.lin[Y - r:Y + r + 1, X - r:X + r + 1].reshape(-1, 3).astype(np.float64)
        for _ in range(3):
            m = np.median(v, axis=0)
            dd = np.linalg.norm(v - m, axis=1)
            k = dd <= np.percentile(dd, 60)
            if k.sum() < 8:
                break
            v = v[k]
        return np.median(v, axis=0)

    def on_click(self, x, y):
        if self.lin is None:
            return
        c = [float(v) for v in self._sample(x, y)]
        if self.view._mode == "grey":
            self.pts.append({"xy": (x, y), "lin": c})
            self.b_fit.setEnabled(len(self.pts) >= 2)
            self.setStatus(f"已加第 {len(self.pts)} 块中性灰"
                           + ("　→ 可以按「解算 γ」了" if len(self.pts) >= 2 else "　（至少两块）"))
        elif self.view._mode == "base":
            self.base_pt = {"xy": (x, y), "lin": c}
            self.rb_base.setChecked(True)
            self.setStatus("零点已设为手动点选。接下来去点中性灰解 γ。")
        self.sync_marks()
        self.schedule()

    def sync_marks(self):
        m = [(p["xy"][0], p["xy"][1], "grey") for p in self.pts]
        if self.base_pt:
            m.append((self.base_pt["xy"][0], self.base_pt["xy"][1], "base"))
        self.view.set_marks(m)
        self._sync_steps()

    def clear_grey(self):
        self.pts, self.cal_t0 = [], None
        self.b_fit.setEnabled(False)
        self.sync_marks()
        self.schedule()

    def clear_base(self):
        self.base_pt = None
        self.rb_scene.setChecked(True)
        self.sync_marks()
        self.schedule()

    def cur_t0(self):
        if self.base_pt is not None:
            return np.maximum(np.array(self.base_pt["lin"], np.float64), 1e-6)
        return np.maximum(np.array([np.percentile(self.proxy[:, :, i], 99.95)
                                    for i in range(3)]), 1e-6)

    def do_fit(self):
        if len(self.pts) < 2:
            QMessageBox.information(self, "还差一点",
                                    "至少要点两块中性灰，而且亮度要拉开。\n\n"
                                    "只点一块的话，「斜率」和「偏移」分不开 —— "
                                    "这正是 RawTherapee 也要求你点两块的原因。")
            return
        t0 = self.cur_t0()
        try:
            g, o, sr, res, _ = fit_gamma([p["lin"] for p in self.pts], t0)
        except Exception as e:
            QMessageBox.critical(self, "解算失败", str(e))
            return
        for s, v in ((self.sl_gR, float(g[0])), (self.sl_gB, float(g[2]))):
            s.blockSignals(True)
            s.setValue(int(round((v - s._lo) / s._step)))
            s.blockSignals(False)
        self.lb_gR.setText(f"{g[0]:.3f}")
        self.lb_gB.setText(f"{g[2]:.3f}")
        self.offset = [float(v) for v in o]
        self.l_ref = float(np.mean(-np.asarray(self.offset) / np.maximum(np.asarray(g), 1e-9)))
        self.cal_t0 = t0
        good = sr < 0.06
        self.lbl_fit.setText(
            f"γ = {g[0]:.4f} : 1 : {g[2]:.4f}　"
            f"<span style='color:{C_OK if good else C_WARN}'>σ2/σ1 = {sr*100:.2f}%"
            f"　{'这批点够中性 ✅' if good else '不够中性 ⚠️（换位置再点，或检查零点）'}</span>")
        self.setStatus("γ 已更新 —— 存下来，同型号同链路可长期复用。")
        self._sync_steps()
        self.schedule()

    # ------------------------------------------------- 渲染

    def schedule(self):
        if self._pending:
            return
        self._pending = True
        QTimer.singleShot(50, self._render)

    def _params(self):
        """返回 (t0, γ, offset, L_ref, exposure, black)。

        ★ 一处我做错又改回来的地方，记在这里免得再犯：
          曾经想给偏移做「跨帧规范变换」 o_B = o_A + log10(T0_B/T0_A)。
          **不需要，而且是错的。** 代数上：

              A 帧解出：  o_c = γ_c·(L̄ − L0_A)      （L̄ = 灰阶的平均曝光）
                          L_ref = −(L̄ − L0_A)
              B 帧反相：  Pi_c = γ_c·(L − L0_B)
              L_c − L_ref = (L − L0_B) − o_c/γ_c − L_ref = L − L0_B   ← 三通道相同

          也就是说：**偏移 o 和 L_ref 是常数，不该动**；每帧的零点通过 Pi 自己进去。
          真正决定成败的是「L0_B 是不是真的 0」—— 这一帧的「最亮像素」到底是不是
          未曝光片基、是不是中性。这就是手动点片基比自动猜准得多的原因。
          （数值验证：不加平移时三种零点情形下输出最大通道差 0.0000004 档。）
        """
        t0 = self.cur_t0()
        gamma = [float(self.slv(self.sl_gR)), 1.0, float(self.slv(self.sl_gB))]
        return (t0, gamma, self.offset, self.l_ref,
                2.0 ** self.slv(self.sl_exp), self.slv(self.sl_blk))

    def _render(self):
        self._pending = False
        if self.proxy is None:
            return
        try:
            t0, g, o, lr, ex, bk = self._params()
            L = invert(self.proxy, t0, g, o, lr, ex, bk)
            self.view.set_image(to_display(L))
            self._readouts(L, t0, g, o, lr)
        except Exception:
            self.txt.setPlainText(traceback.format_exc()[-1800:])

    def _readouts(self, L, t0, g, o, lr):
        h = health(self.proxy, t0)
        color = C_OK if h["level"] == "ok" else C_WARN
        self.lbl_health.setText(
            f"R/G/B 唯一值 {h['R']['unique']}/{h['G']['unique']}/{h['B']['unique']}　"
            f"撞密度上限 {h['capped']}%<br>"
            f"<span style='color:{color}'>{h['verdict']}</span>")
        s = ["── 输入 ──",
             f"  编码       {self.info.get('encoding','?')}",
             f"  唯一值     R{h['R']['unique']}  G{h['G']['unique']}  B{h['B']['unique']}",
             f"  通道抠死   B {h['B']['crush']}%  饱和 B {h['B']['sat']}%",
             f"  撞密度上限 {h['capped']}%（上限 {PI_CLIP}）",
             f"  判定       {h['verdict']}",
             "",
             "── 零点（每帧定）──",
             f"  来源       {'手动点选' if self.base_pt is not None else '画面最亮 0.05%'}",
             f"  T0         {np.round(t0,5).tolist()}",
             "",
             "── γ（一次性）──",
             f"  γ (R:G:B)  {np.round(g,4).tolist()}",
             f"  偏移 o     {np.round(o,4).tolist()}",
             f"  L_ref      {lr:.4f}",
             ""]
        if self.cal_t0 is not None and self.pts:
            arr = np.array([p["lin"] for p in self.pts], np.float32)
            Lp = np.squeeze(np.maximum(invert(arr[None, :, :], t0, g, o, lr), 1e-7))
            dev = np.abs(np.log2(Lp) - np.log2(Lp)[:, 1:2]).max(axis=1)
            mx = float(dev.max())
            s += ["── ★ 验收：你点的那些灰还剩多少偏色 ──",
                  "  " + "  ".join(f"{v:.4f}" for v in dev) + "  档",
                  f"  最大 {mx:.4f} 档" +
                  ("  ✅" if mx < 0.15 else "  ⚠️ 偏大：这些点可能不是真中性，或零点不对"),
                  ""]
        lum = L @ np.array([0.2126, 0.7152, 0.0722], np.float32)
        m = (lum >= np.percentile(lum, 35)) & (lum <= np.percentile(lum, 65))
        med = np.median(L[m], axis=0)
        s += ["── 画面（只可横向比）──",
              f"  中间调偏色 {float(np.log2(med.max()/max(med.min(),1e-9))):.3f} 档",
              "",
              "  这一栏不能判方法对错（画面里没有已知中性面）。",
              "  唯一能判对错的是上面那条「你点的灰还剩多少偏色」。"]
        self.txt.setPlainText("\n".join(s))

    # ------------------------------------------------- 存取

    def save_cal(self):
        p, _ = QFileDialog.getSaveFileName(
            self, "保存标定",
            os.path.join(os.path.expanduser("~/Desktop"), "neglab-calibration.json"),
            "JSON (*.json)")
        if not p:
            return
        json.dump({"app": APPNAME, "version": VERSION,
                   "gamma": [float(self.slv(self.sl_gR)), 1.0, float(self.slv(self.sl_gB))],
                   "offset": [float(v) for v in self.offset],
                   "L_base": float(self.l_ref),
                   "source": self.info.get("name", ""),
                   "note": "γ 是一次性的（型号 × 链路）；零点每帧重定。"
                           "offset 只在与其同时解出的那个零点下有效。"},
                  open(p, "w"), ensure_ascii=False, indent=1)
        self.setStatus("已保存 " + p)

    def load_cal(self):
        p, _ = QFileDialog.getOpenFileName(self, "载入标定",
                                           os.path.expanduser("~/Desktop"), "JSON (*.json)")
        if not p:
            return
        d = json.load(open(p))
        for s, v in ((self.sl_gR, d["gamma"][0]), (self.sl_gB, d["gamma"][2])):
            s.blockSignals(True)
            s.setValue(int(round((v - s._lo) / s._step)))
            s.blockSignals(False)
        self.lb_gR.setText(f"{d['gamma'][0]:.3f}")
        self.lb_gB.setText(f"{d['gamma'][2]:.3f}")
        self.offset = d.get("offset", [0.0, 0.0, 0.0])
        self.l_ref = d.get("L_base", 0.0)
        self.cal_t0 = None
        self.lbl_fit.setText(
            f"γ = {d['gamma'][0]:.4f} : 1 : {d['gamma'][2]:.4f}　"
            f"<span style='color:{C_MUT}'>（来自 {os.path.basename(p)}；"
            f"若换了零点，建议重新点灰解一次）</span>")
        self.setStatus("已载入标定 " + p)
        self.schedule()

    def export(self, kind):
        if self.lin is None:
            return
        t0, g, o, lr, ex, bk = self._params()
        base = os.path.splitext(self.info.get("name", "out"))[0]
        ext = "_linear16.tif" if kind == "tif" else ".jpg"
        d, _ = QFileDialog.getSaveFileName(
            self, "导出", os.path.join(os.path.expanduser("~/Desktop"), base + ext))
        if not d:
            return
        import cv2
        L = invert(self.lin, t0, g, o, lr, ex, bk)
        if kind == "tif":
            arr = np.clip(L / max(float(np.percentile(L[:, :, 1], 99.9)), 1e-9), 0, 1)
            cv2.imwrite(d, (arr * 65535.0 + 0.5).astype(np.uint16)[:, :, ::-1])
        else:
            cv2.imwrite(d, to_display(L), [cv2.IMWRITE_JPEG_QUALITY, 95])
        self.setStatus("已导出 " + d)


def main():
    app = QApplication(sys.argv)
    app.setApplicationName(APPNAME)
    app.setApplicationDisplayName(APPNAME)
    w = Win()
    w.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
