#!/bin/bash
# build_app.sh —— 把 NegLab 编成 /Applications 里那种可以双击的 .app
#
# 为什么能这么小、这么干净：界面是 AppKit 原生，图像解码走 macOS 自带的
# ImageIO 和 Core Image，数学是一个不依赖任何库的 .m 文件。
# 所以成品是几百 KB，不打包 Python、不打包 Qt，用户不需要装任何东西。
#
# 用法：  ./build_app.sh            编出 ./NegLab.app
#         ./build_app.sh --install  再拷到 /Applications
#         ./build_app.sh --run      编完顺便启动
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/NegLab.app"
BIN="$APP/Contents/MacOS/NegLab"
VER="1.0"

echo "── 清理"
rm -rf "$APP"

echo "── 编译（clang，Objective-C ARC）"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -O2 -fobjc-arc -Wall \
      -mmacosx-version-min=12.0 \
      -Wno-deprecated-declarations \
      -framework Cocoa -framework ImageIO -framework CoreImage \
      -framework QuartzCore -framework UniformTypeIdentifiers -framework Foundation \
      -o "$BIN" \
      "$HERE/main.m" "$HERE/NegImage.m" "$HERE/NegMath.m"

echo "── 组装 bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>NegLab</string>
  <key>CFBundleDisplayName</key>       <string>NegLab</string>
  <key>CFBundleExecutable</key>        <string>NegLab</string>
  <key>CFBundleIdentifier</key>        <string>dev.neglab.app</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundleVersion</key>           <string>${VER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key>    <string>12.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>胶片负片</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.tiff</string>
        <string>public.png</string>
        <string>public.jpeg</string>
        <string>com.canon.cr2-raw-image</string>
        <string>com.canon.cr3-raw-image</string>
        <string>com.sony.arw-raw-image</string>
        <string>com.nikon.raw-image</string>
        <string>com.adobe.raw-image</string>
        <string>com.fuji.raw-image</string>
        <string>com.panasonic.rw2-raw-image</string>
        <string>com.olympus.raw-image</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# 签一下（ad-hoc 就够）。不签的话，从别的机器拷过来会被 Gatekeeper 拦。
codesign --force --sign - --identifier dev.neglab.app "$APP" 2>/dev/null || \
  echo "   （ad-hoc 签名跳过，不影响本机运行）"

SIZE=$(du -sh "$APP" | cut -f1 | tr -d ' ')
echo "── 完成：${APP}　大小 ${SIZE}"

if [[ "${1:-}" == "--install" ]]; then
  echo "── 拷到 /Applications（可能要输密码）"
  rm -rf "/Applications/NegLab.app"
  cp -R "$APP" /Applications/
  echo "   已安装：/Applications/NegLab.app"
fi

if [[ "${1:-}" == "--run" ]]; then
  open "$APP"
fi
