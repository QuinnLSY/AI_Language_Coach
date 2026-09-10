#!/bin/zsh
# AI Language Coach — .app 打包脚本
# 用法: Scripts/make_app.sh          → 构建并输出 dist/AI_Language_Coach.app
#       Scripts/make_app.sh --no-build → 只重新组装（用现有 release 产物）
# 产物极简：二进制（strip 后）+ SwiftPM 资源 bundle（Contents/Resources）+ Info.plist + 图标，
# 最后做 ad-hoc 签名（TCC 授权持久化所需，见下文第 5 步）。
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

# 2) SwiftPM 资源 bundle → Contents/Resources（标准位置）。
#    ⚠️ 不要放 .app 根目录：codesign 会报 "unsealed contents present in the bundle root"，
#    导致整个 .app 无法签名；未签名 → TCC 拿不到稳定身份 → 麦克风授权每次重启都重弹。
#    代码侧由 AIInfrastructure/AppResourceBundle 负责查找（标准位置优先）。
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/$BUNDLE_RES_NAME"

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

# 5) ad-hoc 签名（必须在上面的 strip 之后，否则改二进制会让签名失效）。
#    ⚠️ 为什么必须签：未签名的 .app 在 TCC 里没有稳定代码身份，麦克风授权无法持久化，
#    每次启动都会重新弹系统授权框（2026-09-10 实测）。strip 之后旧签名已失效，
#    因此这里统一重签一遍。资源已挪到 Contents/Resources，根目录只剩 Contents，可以正常签。
ENTITLEMENTS="$ROOT/Scripts/app.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" "$APP" \
    || { echo "✗ 签名失败"; exit 1; }
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" \
    || { echo "✗ 签名失败"; exit 1; }
fi
codesign -v "$APP" || { echo "✗ 签名校验未通过"; exit 1; }

SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ 打包完成: $APP ($SIZE)"
echo "  双击运行，或: open '$APP'"
