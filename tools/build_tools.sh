#!/bin/bash
# build_tools.sh —— 编译命令行工具。
# 只用 macOS 自带框架，不需要 brew、不需要 pip、不需要 Xcode 工程文件。
#
# 生成的四个可执行文件都不入版本库（见 .gitignore），本机编一次即可。
set -euo pipefail
cd "$(dirname "$0")"

FRAMEWORKS="-framework Foundation -framework CoreImage -framework ImageIO -framework CoreGraphics"
CFLAGS="-O2 -Wall"

echo "① mathtest —— 数学核心自检（5 项）"
clang $CFLAGS -o mathtest mathtest.m ../app/NegMath.m -lm

echo "② imgtest —— 图像解码自检（看清每张片子被解释成了什么）"
clang $CFLAGS -fobjc-arc -Wno-deprecated-declarations $FRAMEWORKS \
  -o imgtest imgtest.m ../app/NegImage.m ../app/NegMath.m

echo "③ calib_cli —— 标定与批量反相"
clang $CFLAGS -fobjc-arc -Wno-deprecated-declarations $FRAMEWORKS \
  -o calib_cli calib_cli.m ../app/NegImage.m ../app/NegMath.m

echo "④ raw2linear —— 相机 raw → 16-bit 线性 TIFF"
clang $CFLAGS -fobjc-arc -Wno-deprecated-declarations $FRAMEWORKS \
  -o raw2linear raw2linear.m

echo
echo "════── 跑一遍自检 ──════"
./mathtest
echo
./calib_cli --selftest
echo
echo "✅ 全部生成于 $(pwd)"
