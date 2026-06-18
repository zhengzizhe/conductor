#!/usr/bin/env bash
# 发布打包：分别构建 arm64 / x86_64 两个架构的 Conductor.app，并各自打成 DMG。
#
# 注意：交叉编译（如 Intel 机器打 arm64）要求工具链带目标架构的运行时库；
# Homebrew 的 swift 是单架构 bottle，链接阶段会缺 arm64 库——这种情况请装
# swift.org 官方 toolchain 或 Xcode，再跑本脚本。
#
# 用法：
#   Scripts/make-dmg.sh                # 打 arm64 + x86_64 两个 DMG
#   Scripts/make-dmg.sh arm64          # 只打 arm64
#   Scripts/make-dmg.sh x86_64         # 只打 x86_64
#   Scripts/make-dmg.sh universal      # 打单个双架构（universal）DMG
#   VERSION=0.0.9 Scripts/make-dmg.sh  # 覆盖版本号（默认 0.0.9）
#
# 产物：dist/conductor-<version>-<arch>.dmg
# 依赖：Vendor/GhosttyKit.xcframework（universal 静态库，缺失时先跑 Scripts/prepare-ghosttykit.sh）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.9}"
BUNDLE_ID="com.conductor.app"
APP_NAME="Conductor"
DIST="$ROOT/dist"
SIGN_IDENTITY="${CONDUCTOR_SIGN_IDENTITY:-Conductor Dev}"

# 交叉编译时部分工具链的 prebuilt 模块缓存与 SDK 不匹配会让编译器崩溃
# （DESERIALIZATION FAILURE）；统一重定向到空目录，强制从 swiftinterface 构建。
PREBUILT_OVERRIDE="$(mktemp -d "${TMPDIR:-/tmp}/conductor-prebuilt.XXXXXX")"
trap 'rm -rf "$PREBUILT_OVERRIDE"' EXIT
PREBUILT_FLAGS=(-Xswiftc -Xfrontend -Xswiftc -prebuilt-module-cache-path
                -Xswiftc -Xfrontend -Xswiftc "$PREBUILT_OVERRIDE")

if [[ ! -d "$ROOT/Vendor/GhosttyKit.xcframework" ]]; then
  echo "==> 缺少 GhosttyKit，先执行 Scripts/prepare-ghosttykit.sh"
  "$ROOT/Scripts/prepare-ghosttykit.sh"
fi

# 把指定 bin 目录里的产物组装成 .app（与 make-app.sh 同构）。
assemble_app() {
  local bin_dir="$1" app="$2"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin_dir/ConductorApp" "$app/Contents/MacOS/ConductorApp"
  cp "$bin_dir/ConductorUpdater" "$app/Contents/MacOS/ConductorUpdater"
  cp "$bin_dir/conductorctl" "$app/Contents/MacOS/conductorctl"

  # 每个带资源的 target（ConductorApp / ConductorCore）都有自己的 bundle，缺一个
  # Bundle.module 访问就会 fatalError。
  local bundle
  for bundle in "$bin_dir"/Conductor_*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
  done

  # 应用图标
  cp "$ROOT/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

  cat > "$app/Contents/Info.plist" <<PLIST
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
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
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

  # macOS 的 TCC 权限按代码签名身份记账。优先使用稳定签名身份，避免每次
  # 重打包后桌面/文稿/下载、完全磁盘访问、通知等授权被系统当成新 app。
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "==> 用稳定签名身份「${SIGN_IDENTITY}」签名 $app"
    codesign --force --sign "$SIGN_IDENTITY" "$app/Contents/MacOS/ConductorUpdater"
    codesign --force --sign "$SIGN_IDENTITY" "$app/Contents/MacOS/conductorctl"
    if [ -f "$ROOT/Conductor.entitlements" ]; then
      codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Conductor.entitlements" "$app"
    else
      codesign --force --sign "$SIGN_IDENTITY" "$app"
    fi
  else
    echo "==> 未找到稳定身份「${SIGN_IDENTITY}」，退回 ad-hoc 签名"
    echo "    ⚠️  ad-hoc 下每次重打包都会丢失 TCC 授权；先运行 Scripts/make-dev-cert.sh 可根治。"
    codesign --force --sign - "$app/Contents/MacOS/conductorctl" >/dev/null 2>&1 || \
      echo "   (conductorctl codesign 失败，可忽略)"
    codesign --force --sign - "$app/Contents/MacOS/ConductorUpdater" >/dev/null 2>&1 || \
      echo "   (ConductorUpdater codesign 失败，可忽略)"
    codesign --force --sign - "$app" >/dev/null 2>&1 || \
      echo "   (codesign 失败，可忽略；通知可能需要手动授权)"
  fi
}

# 把 .app 打成带 /Applications 软链的压缩 DMG。
make_dmg() {
  local app="$1" dmg="$2"
  local staging
  staging="$(mktemp -d "${TMPDIR:-/tmp}/conductor-dmg.XXXXXX")"

  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"

  rm -f "$dmg"
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO -quiet "$dmg"
  rm -rf "$staging"
}

# 构建一个目标：arch 取 arm64 / x86_64 / universal。
build_one() {
  local target="$1"
  local arch_flags=() bin_dir suffix

  case "$target" in
    arm64)     arch_flags=(--arch arm64);              suffix="arm64" ;;
    x86_64)    arch_flags=(--arch x86_64);             suffix="x86_64" ;;
    universal) arch_flags=(--arch arm64 --arch x86_64); suffix="universal" ;;
    *) echo "未知架构：$target（支持 arm64 / x86_64 / universal）" >&2; exit 1 ;;
  esac

  echo "==> swift build -c release ${arch_flags[*]}"
  swift build -c release "${arch_flags[@]}" --product ConductorApp "${PREBUILT_FLAGS[@]}"
  swift build -c release "${arch_flags[@]}" --product ConductorUpdater "${PREBUILT_FLAGS[@]}"
  swift build -c release "${arch_flags[@]}" --product conductorctl "${PREBUILT_FLAGS[@]}"

  bin_dir="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

  local app="$DIST/$suffix/$APP_NAME.app"
  local dmg="$DIST/$APP_NAME-$VERSION-$suffix.dmg"

  echo "==> 组装 $app"
  mkdir -p "$DIST/$suffix"
  assemble_app "$bin_dir" "$app"

  echo "==> 打包 $dmg"
  make_dmg "$app" "$dmg"

  lipo -info "$app/Contents/MacOS/ConductorApp" | sed 's/^/    /'
  lipo -info "$app/Contents/MacOS/ConductorUpdater" | sed 's/^/    /'
  lipo -info "$app/Contents/MacOS/conductorctl" | sed 's/^/    /'
  du -sh "$dmg" | sed 's/^/    /'
}

mkdir -p "$DIST"

if [[ $# -ge 1 ]]; then
  targets=("$@")
else
  targets=(arm64 x86_64)
fi

for t in "${targets[@]}"; do
  build_one "$t"
done

echo "==> 全部完成，产物："
ls -lh "$DIST"/*.dmg | awk '{print "    " $9 "  (" $5 ")"}'
