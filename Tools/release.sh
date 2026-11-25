#!/bin/zsh
# 在本机打发布包（做法同 PeekBox）：Apple Development 证书签名，Sparkle 私钥从登录钥匙串读，生成 appcast.xml。
#
#   Tools/release.sh                   # 只打包和检查，产物在 dist/
#   Tools/release.sh --draft-release   # 再用 gh 建草稿 Release（标签 v<版本>，打在公开仓库的 main 上），附上 zip、校验文件和 appcast
#
# 为什么不用 ad-hoc：“设备控制和数据访问”授权认的是签名的指定要求。证书签名的指定要求是“标识符 + 证书名”，
# 每个版本都一样，应用内更新后授权还在；ad-hoc 的指定要求是这次构建的哈希，每个版本都要重新授权（遗留清单 L167）。
# 证书和 Sparkle 私钥都只在本机，所以发布包在本机打，不走 CI。
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=32N23TW5BT
REPO=davie-01/Xpaste

SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=$TEAM SPARKLE_SIGN_WITH_KEYCHAIN=1 Tools/package.sh

APP=build/package/DerivedData/Build/Products/Release/XPaste.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
NAME="XPaste-${VERSION}-arm64"

fail() { echo "错误：$1" >&2; exit 1; }
SIGNING=$(codesign -dv --verbose=2 "$APP" 2>&1)
[[ "$SIGNING" == *"Authority=Apple Development:"* && "$SIGNING" == *"TeamIdentifier=$TEAM"* ]] || fail "发布包不是用 Team $TEAM 的 Apple Development 证书签的"
# 只用证书签名，不带描述文件；带了别人机器上会因为设备不在描述文件里而打不开。
if find "$APP" -name embedded.provisionprofile | grep -q .; then fail "产物中包含 embedded.provisionprofile"; fi
[[ -f dist/appcast.xml ]] || fail "没有生成 appcast.xml"
grep -q "<sparkle:version>$BUILD</sparkle:version>" dist/appcast.xml || fail "appcast 里的构建号不是 $BUILD"
grep -q "releases/download/v$VERSION/$NAME.zip" dist/appcast.xml || fail "appcast 里的下载地址不对"
[[ $(grep -c '<description sparkle:format="markdown"' dist/appcast.xml) == 2 ]] || fail "appcast 里没有中英文两段更新说明"
echo "发布检查通过：$VERSION（$BUILD），$(codesign -d -r- "$APP" 2>&1 | grep designated)"

if [[ "${1:-}" == "--draft-release" ]]; then
  command -v gh >/dev/null || fail "需要 GitHub 命令行工具：brew install gh"
  # Release 正文：英文、中文两份更新说明，加安装提示。
  BODY=build/package/release-notes.md
  {
    cat "ReleaseNotes/$VERSION.en.md"; printf '\n\n---\n\n'
    cat "ReleaseNotes/$VERSION.zh-Hans.md"; printf '\n\n---\n\n'
    echo "Signed with an Apple Development certificate, not notarized. See README for installation."
  } >"$BODY"
  gh release create "v$VERSION" "dist/$NAME.zip" "dist/$NAME.zip.sha256" dist/appcast.xml \
    -R "$REPO" --target main --draft --title "XPaste v$VERSION" --notes-file "$BODY"
  echo "已建草稿 Release v$VERSION，检查后再发布（Docs/release.md 第 5 节）。"
fi
