#!/bin/bash
# 编译 raw2linear（相机 raw → 16-bit 线性 TIFF）。
# 只用 macOS 自带框架，不需要 brew、不需要 pip。
set -e
cd "$(dirname "$0")"
echo "正在编译 raw2linear …"
clang -O2 -fobjc-arc -Wno-deprecated-declarations \
  -framework Foundation -framework CoreImage \
  -framework ImageIO -framework CoreGraphics \
  -o raw2linear raw2linear.m
echo "✅ 生成 $(pwd)/raw2linear"
./raw2linear --list 2>/dev/null || true
