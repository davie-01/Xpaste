#!/bin/zsh
# 打发布包：Release 构建、剥离符号、签名，压成 zip 并生成 SHA-256 校验文件。
#
#   Tools/package.sh                 # ad-hoc 签名（没有 Apple 开发者证书也能打包）
#   SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=XXXXXXXXXX Tools/package.sh   # 用自己的证书
#
# 产物在 dist/：XPaste-<版本>-arm64.zip 和同名的 .sha256。
# ad-hoc 签名的包没有公证，下载后要先去掉隔离属性才能打开（见 README）；每次重新打包签名都会变，
# “设备控制和数据访问”（辅助功能）授权需要重新勾选。
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=${SIGN_IDENTITY:--}
DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}
DERIVED=build/package/DerivedData
DIST=dist

command -v xcodegen >/dev/null || { echo "需要 XcodeGen：brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

rm -rf "$DERIVED"
mkdir -p "$DIST" build/package
echo "构建 Release（签名：${SIGN_IDENTITY}）…"
xcodebuild -project XPaste.xcodeproj -scheme XPaste -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global \
  build >build/package/build.log 2>&1 || { tail -30 build/package/build.log; echo "构建失败，完整日志：build/package/build.log" >&2; exit 1; }

APP="$DERIVED/Build/Products/Release/XPaste.app"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="XPaste-${VERSION}-arm64"

rm -f "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
(cd "$DIST" && shasum -a 256 "$NAME.zip" >"$NAME.zip.sha256")

echo "完成："
du -h "$DIST/$NAME.zip"
cat "$DIST/$NAME.zip.sha256"
