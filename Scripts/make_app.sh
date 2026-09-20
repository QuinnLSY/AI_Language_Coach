#!/bin/zsh
# AI Language Coach — .app 打包脚本
# 用法: Scripts/make_app.sh                  → 构建并输出 dist/AI_Language_Coach.app
#       Scripts/make_app.sh --no-build       → 只重新组装（用现有 release 产物）
#       Scripts/make_app.sh --universal      → 同时出 arm64 + x86_64（产物约翻倍，慢一倍）
#       Scripts/make_app.sh --optimize-size  → 加 -Osize（换体积，略微牺牲峰值性能）
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

# 必须随包的资源 bundle（SwiftPM 由 target 名生成）。
# ⚠️ 这里只用于**兜底断言**：真正拷贝走通配（见第 2 步），
# 新加资源 target 不必改脚本；但已知的这两个必须在，缺了要在打包时就吼出来 ——
# 少拷一个包的表现是「某个资源静默取不到 → 走兜底外观」，不报错，最难查。
REQUIRED_BUNDLES=("AILanguageCoach_AIInfrastructure" "AILanguageCoach_AppUI")

# 版本号唯一来源：Scripts/version.env（脚本不硬编码版本，避免与「关于」显示漂移）
VERSION_ENV="$ROOT/Scripts/version.env"
if [[ -f "$VERSION_ENV" ]]; then
  source "$VERSION_ENV"
else
  echo "✗ 缺少 $VERSION_ENV"; exit 1
fi
: "${MARKETING_VERSION:?version.env 缺少 MARKETING_VERSION}"
: "${BUILD_VERSION:?version.env 缺少 BUILD_VERSION}"

NO_BUILD=0
UNIVERSAL=0
OPTIMIZE_SIZE=0
for arg in "$@"; do
  case "$arg" in
    --no-build) NO_BUILD=1 ;;
    --universal) UNIVERSAL=1 ;;
    --optimize-size) OPTIMIZE_SIZE=1 ;;
    --help|-h)
      sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "✗ 未知参数：$arg（见 --help）"; exit 1 ;;
  esac
done

cd "$ROOT"

BUILD_ARGS=(build -c release --disable-sandbox)
[[ "$UNIVERSAL" == 1 ]] && BUILD_ARGS+=(--arch arm64 --arch x86_64)
[[ "$OPTIMIZE_SIZE" == 1 ]] && BUILD_ARGS+=(-Xswiftc -Osize)
if [[ "$NO_BUILD" == 0 ]]; then
  echo "▸ swift ${BUILD_ARGS[*]}"
  swift "${BUILD_ARGS[@]}"
fi

# release 产物目录：单架构在 .build/release；多架构（--arch ×2）时 SwiftPM 改走
# .build/apple/Products/Release —— 两个位置都探，别写死一个。
RELEASE_DIR=""
for candidate in ".build/release" ".build/apple/Products/Release"; do
  if [[ -x "$candidate/$EXEC_NAME" ]]; then RELEASE_DIR="$candidate"; break; fi
done
[[ -n "$RELEASE_DIR" ]] || { echo "✗ 找不到 release 产物（先执行构建，或去掉 --no-build）"; exit 1; }
BIN="$RELEASE_DIR/$EXEC_NAME"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) 二进制（strip 掉符号表，减小体积）
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
strip -x "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"

# 2) 全部 SwiftPM 资源 bundle → Contents/Resources（标准位置）。
#    ⚠️ 不要放 .app 根目录：codesign 会报 "unsealed contents present in the bundle root"，
#    导致整个 .app 无法签名；未签名 → TCC 拿不到稳定身份 → 麦克风授权每次重启都重弹。
#    代码侧由 AIInfrastructure/AppResourceBundle 与 AppUI/UIAssetBundle 查找（标准位置优先）。
#    通配拷贝：脚本与 target 名解耦，新加资源 target 自动随包。
RES_BUNDLES=("$ROOT"/$RELEASE_DIR/*.bundle(N))
(( ${#RES_BUNDLES[@]} > 0 )) || { echo "✗ $RELEASE_DIR 下没有资源 bundle（检查 Package.swift 的 resources:）"; exit 1; }
for bundle in "${RES_BUNDLES[@]}"; do
  cp -R "$bundle" "$APP/Contents/Resources/"
  echo "  · $(basename "$bundle")"
done
for name in "${REQUIRED_BUNDLES[@]}"; do
  [[ -d "$APP/Contents/Resources/$name.bundle" ]] \
    || { echo "✗ 缺少 $name.bundle（该 target 的 resources: [.copy(\"Resources\")] 没了？）"; exit 1; }
done

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
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
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
ARCHS=$(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo "?")
echo "✓ 打包完成: $APP ($SIZE · $ARCHS)  v$MARKETING_VERSION (build $BUILD_VERSION)"
echo "  双击运行，或: open '$APP'"
