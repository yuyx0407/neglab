#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_app.py —— 把 neglab.py 打成 macOS 的 .app 包。

为什么不用 py2app / PyInstaller：
  · 只依赖系统 Python 3.11（python.org 版）里已有的 PySide6 / cv2 / numpy，零安装。
  · py2app 会把 Qt 整套（几百 MB）重新拷一遍，还容易在 Qt plugin 路径上翻车。
  · 这里用「启动器 + 资源」结构：Info.plist + Contents/MacOS/NegLab（shell）
    + Contents/Resources/*.py，ad-hoc 签名即可双击运行。整包 ~220 KB。

用法： python3 app/build_app.py
"""
import os
import plistlib
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
APPNAME = "NegLab"
APP = os.path.join(ROOT, APPNAME + ".app")
PY311 = "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"

SRC = ["neglab.py", "demask.py"]
TOOLS = [os.path.join(ROOT, "tools", "raw2linear")]

LAUNCHER = """#!/bin/zsh
# NegLab 启动器。用系统 Python 3.11（PySide6 / cv2 / numpy 都在里面）。
#
# ⚠️ 一个必须记下来的坑：LaunchServices 启动 shell 脚本时会跑到 x86_64（Rosetta）下，
#    而 python.org 的 numpy 只有 arm64 切片 →
#    ImportError: mach-o file, but is an incompatible architecture (have 'arm64', need 'x86_64')
#    **直接跑 Contents/MacOS/NegLab 不会踩，只有双击才踩。**
#    排查方法：下面把 stdout/stderr 追加到 ~/Library/Logs/NegLab-launch.log
#    （LaunchServices 会把输出丢掉，不写文件就什么都看不到）。
DIR="$(cd "$(dirname "$0")/../Resources" && pwd)"
PY="%s"
if [ ! -x "$PY" ]; then
  osascript -e 'display alert "找不到 Python 3.11" message "NegLab 依赖 /Library/Frameworks/Python.framework/Versions/3.11。请先安装 python.org 的 Python 3.11。"'
  exit 1
fi
export PYTHONNOUSERSITE=1
cd "$DIR" || exit 1
LOG="$HOME/Library/Logs/NegLab-launch.log"
{ echo "=== $(date) ==="; echo "DIR=$DIR"; echo "PY=$PY exists=$([ -x "$PY" ] && echo yes || echo no)"; } >> "$LOG" 2>&1
arch -arm64 "$PY" "$DIR/neglab.py" "$@" >> "$LOG" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  echo "arch -arm64 失败（rc=$RC），退回直接跑" >> "$LOG"
  "$PY" "$DIR/neglab.py" "$@" >> "$LOG" 2>&1
  RC=$?
fi
echo "exit=$RC  $(date)" >> "$LOG"
""" % PY311


def make_icon(path):
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return False
    s = 1024
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    r = 200
    d.rounded_rectangle([40, 40, s - 40, s - 40], radius=r, fill=(28, 28, 32, 255))
    d.rounded_rectangle([90, 90, s // 2 - 8, s - 90], radius=r // 2, fill=(196, 118, 42, 255))
    for i in range(6):
        v = int(30 + i * 44)
        x0 = s // 2 + 8
        w = (s - 90 - x0) / 6
        d.rectangle([x0 + i * w, 90, x0 + (i + 1) * w - 3, s - 90], fill=(v, v, v, 255))
    d.rounded_rectangle([90, 90, s - 90, s - 90], radius=r // 2,
                        outline=(240, 240, 240, 255), width=8)
    im.save(path)
    return True


def main():
    if os.path.exists(APP):
        shutil.rmtree(APP)
    macos = os.path.join(APP, "Contents", "MacOS")
    res = os.path.join(APP, "Contents", "Resources")
    os.makedirs(macos)
    os.makedirs(res)

    for f in SRC:
        src = os.path.join(HERE, f)
        if not os.path.exists(src):
            print("缺文件:", src)
            return 1
        shutil.copy2(src, os.path.join(res, f))
    for f in TOOLS:
        if os.path.exists(f):
            shutil.copy2(f, os.path.join(res, os.path.basename(f)))
            os.chmod(os.path.join(res, os.path.basename(f)), 0o755)
            print("  随包带上:", os.path.basename(f))
        else:
            print("  ⚠️ 缺工具（raw 导入会退回手动转换）:", f,
                  "\n     先在仓库里跑 tools/build_tools.sh")

    lp = os.path.join(macos, APPNAME)
    open(lp, "w").write(LAUNCHER)
    os.chmod(lp, 0o755)

    icns = ""
    png = os.path.join(res, "icon.png")
    if make_icon(png):
        iconset = os.path.join(ROOT, "_icon.iconset")
        if os.path.exists(iconset):
            shutil.rmtree(iconset)
        os.makedirs(iconset)
        try:
            from PIL import Image
            base = Image.open(png)
            for sz in (16, 32, 64, 128, 256, 512, 1024):
                base.resize((sz, sz), Image.LANCZOS).save(
                    os.path.join(iconset, f"icon_{sz}x{sz}.png"))
                if sz <= 512:
                    base.resize((sz * 2, sz * 2), Image.LANCZOS).save(
                        os.path.join(iconset, f"icon_{sz}x{sz}@2x.png"))
            out = os.path.join(res, "icon.icns")
            subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
            icns = "icon.icns"
        except Exception as e:
            print("（图标生成跳过：%s）" % e)
        finally:
            if os.path.exists(iconset):
                shutil.rmtree(iconset)
    if os.path.exists(png):
        os.remove(png)

    with open(os.path.join(APP, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({
            "CFBundleName": APPNAME,
            "CFBundleDisplayName": "NegLab 去色罩工作台",
            "CFBundleIdentifier": "io.github.neglab.app",
            "CFBundleExecutable": APPNAME,
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "2",
            "LSMinimumSystemVersion": "12.0",
            "NSHighResolutionCapable": True,
            "CFBundleIconFile": icns,
            "NSHumanReadableCopyright": "MIT License",
        }, f)

    subprocess.run(["codesign", "--force", "--deep", "-s", "-", APP], capture_output=True)
    subprocess.run(["xattr", "-cr", APP], capture_output=True)

    sz = sum(os.path.getsize(os.path.join(r, f))
             for r, _, fs in os.walk(APP) for f in fs)
    print(f"→ {APP}  ({sz/1024:.0f} KB)")
    print("  双击即可运行；首次打开若被 Gatekeeper 拦，右键 →「打开」一次即可。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
