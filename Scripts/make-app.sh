#!/usr/bin/env bash
# 把 SwiftPM 可执行 ConductorApp 打包成 Conductor.app（带 bundle id），让原生通知 + 点击跳转可用。
# 用法：Scripts/make-app.sh [debug|release]，默认 release。产物在仓库根目录 Conductor.app。
set -euo pipefail

CONFIG="${1:-release}"
VERSION="${VERSION:-0.0.9}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG --product ConductorApp"
swift build -c "$CONFIG" --product ConductorApp
echo "==> swift build -c $CONFIG --product conductorctl"
swift build -c "$CONFIG" --product conductorctl

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/Conductor.app"
BUNDLE_ID="com.conductor.app"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/ConductorApp" "$APP/Contents/MacOS/ConductorApp"
cp "$BIN_DIR/conductorctl" "$APP/Contents/MacOS/conductorctl"

# SwiftPM 资源 bundle（logo、本地化文案等）放到 Resources/，Bundle.module 会在 main bundle
# 资源路径里找到，且不会像放在 MacOS/ 那样破坏 codesign。
# 注意：每个带资源的 target 都有自己的 bundle（ConductorApp / ConductorCore），缺一个就会在
# Bundle.module 访问时 fatalError。
for bundle in "$BIN_DIR"/Conductor_*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# 应用图标
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleExecutable</key>
  <string>ConductorApp</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>Conductor</string>
  <key>CFBundleDisplayName</key>
  <string>Conductor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Shell Command Script</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>command</string>
      </array>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.apple.terminal.shell-script</string>
      </array>
    </dict>
  </array>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# 代码签名：macOS 的 TCC 权限（桌面/文稿/下载、完全磁盘访问、通知…）是按
# 「代码签名身份」记账的。ad-hoc 签名（--sign -）没有稳定身份，每次重编译 cdhash
# 一变就被当成"新 app"，之前的授权全部作废 → 反复弹框要权限。
# 因此优先用一个稳定的自签名身份签名；身份不变 → 授权重编译后依然有效。
# 一次性创建该身份：Scripts/make-dev-cert.sh （或自定义 CONDUCTOR_SIGN_IDENTITY）。
# 注意：不再用 --deep（已废弃；本 app 无嵌套可执行/框架，GhosttyKit 是静态库）。
SIGN_IDENTITY="${CONDUCTOR_SIGN_IDENTITY:-Conductor Dev}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  echo "==> 用稳定签名身份「${SIGN_IDENTITY}」签名"
  codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/conductorctl"
  if [ -f "$ROOT/Conductor.entitlements" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Conductor.entitlements" "$APP"
  else
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
  fi
else
  echo "==> 未找到稳定身份「${SIGN_IDENTITY}」，退回 ad-hoc 签名"
  echo "    ⚠️  ad-hoc 下每次重编译都会丢失 TCC 授权（桌面/文稿/下载、完全磁盘访问会反复弹框）。"
  echo "    根治：先运行一次  Scripts/make-dev-cert.sh  再重新打包。"
  codesign --force --sign - "$APP/Contents/MacOS/conductorctl" >/dev/null 2>&1 || \
    echo "    (conductorctl codesign 失败，可忽略)"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || \
    echo "    (codesign 失败，可忽略)"
fi

echo "==> 完成：$APP"
echo "    运行：open $APP   （或双击）"
echo "    若仍被问「桌面/文稿/下载」：系统设置 › 隐私与安全性 › 完全磁盘访问 → 加入 Conductor.app（授权一次，签名稳定后永久生效）。"
