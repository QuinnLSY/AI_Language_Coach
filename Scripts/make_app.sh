#!/bin/zsh
# AI Language Coach — .app 打包脚本
# 用法: Scripts/make_app.sh          → 构建并输出 dist/AI_Language_Coach.app
#       Scripts/make_app.sh --no-build → 只重新组装（用现有 release 产物）
# 产物极简：二进制（strip 后）+ SwiftPM 资源 bundle + Info.plist + 图标。
# 数据不进 .app：运行时写入项目空间 .workbuddy/app-config/（见 AppPaths）。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AI_Language_Coach"
EXEC_NAME="AILanguageCoach"
BUNDLE_ID="com.ailanguagecoach.app"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BUNDLE_RES_NAME="AILanguageCoach_AIInfrastructure.bundle"

cd "$ROOT"

if [[ "${1:-}" != "--no-build" ]]; then
  echo "▸ swift build -c release"
  swift build -c release --disable-sandbox
fi

BIN=".build/release/$EXEC_NAME"
RES_BUNDLE=".build/release/$BUNDLE_RES_NAME"
[[ -x "$BIN" ]] || { echo "✗ 缺少 $BIN，先执行构建"; exit 1; }
[[ -d "$RES_BUNDLE" ]] || { echo "✗ 缺少 $RES_BUNDLE"; exit 1; }

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) 二进制（strip 掉符号表，减小体积）
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
strip -x "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"

# 2) SwiftPM 资源 bundle：生成的 Bundle.module 访问器在 Bundle.main.bundleURL 下查找，
#    即 .app 根目录（对用户不可见，Finder 将 .app 视为整体）。
cp -R "$RES_BUNDLE" "$APP/$BUNDLE_RES_NAME"

# 3) Info.plist（一次写完整）
INFO="$APP/Contents/Info.plist"
cat > "$INFO" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI Language Coach</string>
    <key>CFBundleDisplayName</key><string>语林 AI Language Coach</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>0.4.0</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>语林需要使用麦克风进行口语练习与发音识别（完全本地处理，不上传）。</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 AI Language Coach</string>
</dict>
</plist>
PLIST

# 4) 图标（可选：存在 Scripts/icon.iconset 时转 icns 打包）
ICONSET="$ROOT/Scripts/icon.iconset"
if [[ -d "$ICONSET" ]]; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" \
    || { echo "  (图标转换失败，去掉引用)"; /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$INFO" 2>/dev/null || true; }
else
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$INFO" 2>/dev/null || true
fi

plutil -lint "$INFO" >/dev/null || { echo "✗ Info.plist 校验失败"; exit 1; }

# 5) 不做 codesign：本机构建的二进制无 quarantine 属性，双击/`open` 可直接运行。
#    （SwiftPM 资源 bundle 按 Bundle.module 约定放在 .app 根目录，整包签名会报 unsealed contents。）

SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ 打包完成: $APP ($SIZE)"
echo "  双击运行，或: open '$APP'"
