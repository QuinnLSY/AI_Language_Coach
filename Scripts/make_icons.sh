#!/bin/zsh
# 从品牌母版生成 ① .app 图标集（Scripts/icon.iconset）② 侧边栏 logo 位图（AppUI/Resources/Brand）
#
# 用法: Scripts/make_icons.sh
# 母版: Scripts/brand/yulin-app-icon.png —— 必须是 1024 的整数倍正方形、带 alpha 的 PNG
#       （四角透明 = 圆角方形图标；macOS 要求的圆角外留白已包含在母版里）
#
# 为什么母版要留在仓库里：dist/ 已被 .gitignore 忽略，把母版只放在 dist/ 会让图标无法复现。
# 为什么侧栏位图放 AppUI 而不是 AppCore：位图是**界面资产**，只被侧边栏消费；
# AppCore 是各层共享的 Foundation 底座，不该背 UI 图片（且 AppUI 本就依赖 AppCore，反着放会破层级）。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/Scripts/brand/yulin-app-icon.png"
ICONSET="$ROOT/Scripts/icon.iconset"
LOGO_DIR="$ROOT/Sources/AppUI/Resources/Brand"

[[ -f "$MASTER" ]] || { echo "✗ 缺少母版 $MASTER"; exit 1; }

# 母版必须是正方形，否则等比缩放出不了正确图标
read -r W H <<<"$(sips -g pixelWidth -g pixelHeight "$MASTER" | awk '/pixel/{printf "%s ", $2}')"
[[ "$W" == "$H" ]] || { echo "✗ 母版不是正方形: ${W}x${H}"; exit 1; }
[[ "$W" -ge 1024 ]] || { echo "✗ 母版边长 $W < 1024，做不出 1024 档"; exit 1; }

echo "▸ 生成 iconset（母版 ${W}x${H}）"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# iconutil 要求的 10 档：文件名里的尺寸是「点」，@2x 是 2 倍像素
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  px="${spec%% *}"; name="${spec##* }"
  sips -s format png -z "$px" "$px" "$MASTER" --out "$ICONSET/icon_$name.png" >/dev/null
done
ls "$ICONSET" | wc -l | xargs echo "  档位文件数:"

# 立刻验证能转成 icns（转不出来就说明档位不全/命名不对）
iconutil -c icns "$ICONSET" -o /tmp/_verify_appicon.icns
echo "  ✓ icns 转换通过（$(du -h /tmp/_verify_appicon.icns | cut -f1)）"

echo "▸ 生成侧边栏 logo 位图"
mkdir -p "$LOGO_DIR"
# 侧栏最大 36pt；@3x 需要 108px，取 256 给视网膜留足余量。
# 母版自带约 5~7% 的透明外沿（macOS 图标规范里圆角外的留白），不裁——
# 36pt 下每边不到 2pt，裁了反而要引入魔法缩放系数，得不偿失。
sips -s format png -z 256 256 "$MASTER" --out "$LOGO_DIR/brand-logo.png" >/dev/null
ls -la "$LOGO_DIR"

echo "✓ 图标生成完成"
echo "  下一步: Scripts/make_app.sh --no-build 会把 icns 装进 .app"
