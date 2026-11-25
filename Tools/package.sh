#!/bin/zsh
# 打发布包：Release 构建、剥离符号、签名，压成 zip 并生成 SHA-256 校验文件。
#
#   Tools/package.sh                 # ad-hoc 签名（没有 Apple 开发者证书也能打包）
#   SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=XXXXXXXXXX Tools/package.sh   # 用自己的证书
#
# 产物在 dist/：XPaste-<版本>-arm64.zip 和同名的 .sha256。
#
# 应用内更新（Sparkle）：给了签名私钥时，再用 EdDSA 给 zip 签名，生成 dist/appcast.xml，和 zip 一起附到 Release 上。
#   SPARKLE_SIGN_WITH_KEYCHAIN=1 Tools/package.sh   # 私钥在登录钥匙串里（generate_keys 生成的）；正式发布用 Tools/release.sh
#   SPARKLE_PRIVATE_KEY=<私钥> Tools/package.sh      # 私钥从环境变量传（经标准输入交给 sign_update）
# 两个都没给就不生成 appcast（本机试装用的包不需要）。
# 生成 appcast 时必须有这一版的更新说明（markdown）：ReleaseNotes/<版本>.zh-Hans.md 和 ReleaseNotes/<版本>.en.md，
# 嵌进 appcast，Sparkle 发现新版本时在更新窗口里显示，按系统语言挑中文或英文。
# appcast 里的下载地址默认是 https://github.com/davie-01/Xpaste/releases/download/v<版本>/<zip>，所以标签必须是 v<版本>；
# 本机测更新时可用 SPARKLE_DOWNLOAD_URL_PREFIX 换成别的地址。
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

# ad-hoc 签名没有 Team ID：hardened runtime 的库验证会拒绝加载嵌入的 Sparkle.framework，见 Tools/adhoc.entitlements。
ENTITLEMENTS=()
[[ "$SIGN_IDENTITY" == "-" ]] && ENTITLEMENTS=(CODE_SIGN_ENTITLEMENTS="$PWD/Tools/adhoc.entitlements")

rm -rf "$DERIVED"
mkdir -p "$DIST" build/package
echo "构建 Release（签名：${SIGN_IDENTITY}）…"
xcodebuild -project XPaste.xcodeproj -scheme XPaste -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" "${ENTITLEMENTS[@]}" \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global \
  build >build/package/build.log 2>&1 || { tail -30 build/package/build.log; echo "构建失败，完整日志：build/package/build.log" >&2; exit 1; }

APP="$DERIVED/Build/Products/Release/XPaste.app"
codesign --verify --deep --strict "$APP"
# ad-hoc 签名又嵌了框架时，主程序必须带关闭库验证的授权，否则 dyld 在 main 之前就退出（签名本身“有效”，上面的检查看不出来）。
if [[ "$SIGN_IDENTITY" == "-" && -d "$APP/Contents/Frameworks" ]]; then
  codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.cs.disable-library-validation" \
    || { echo "ad-hoc 签名的包缺少 disable-library-validation 授权，嵌入的框架会加载失败" >&2; exit 1; }
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="XPaste-${VERSION}-arm64"

rm -f "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
(cd "$DIST" && shasum -a 256 "$NAME.zip" >"$NAME.zip.sha256")

rm -f "$DIST/appcast.xml"
SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" || "${SPARKLE_SIGN_WITH_KEYCHAIN:-}" == 1 ]]; then
  [[ -x "$SIGN_UPDATE" ]] || { echo "找不到 Sparkle 的 sign_update：$SIGN_UPDATE" >&2; exit 1; }
  NOTES_DIR=${RELEASE_NOTES_DIR:-ReleaseNotes}
  for lang in zh-Hans en; do
    [[ -s "$NOTES_DIR/$VERSION.$lang.md" ]] || { echo "缺少更新说明：$NOTES_DIR/$VERSION.$lang.md" >&2; exit 1; }
    ! grep -q ']]>' "$NOTES_DIR/$VERSION.$lang.md" || { echo "更新说明里不能有 ]]>（会提前结束 CDATA）：$NOTES_DIR/$VERSION.$lang.md" >&2; exit 1; }
  done
  NOTES_ZH=$(<"$NOTES_DIR/$VERSION.zh-Hans.md")
  NOTES_EN=$(<"$NOTES_DIR/$VERSION.en.md")
  echo "给更新包签名（EdDSA）…"
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # 私钥从标准输入传，不出现在命令行参数里。
    SIGNATURE=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DIST/$NAME.zip")
  else
    SIGNATURE=$("$SIGN_UPDATE" "$DIST/$NAME.zip")
  fi
  # 输出形如：sparkle:edSignature="…" length="…"
  [[ "$SIGNATURE" == *'sparkle:edSignature="'*'length="'* ]] || { echo "签名输出不对：$SIGNATURE" >&2; exit 1; }
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  MIN_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
  REPO_URL=https://github.com/davie-01/Xpaste
  PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-$REPO_URL/releases/download/v$VERSION}
  PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
  cat >"$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>XPaste</title>
    <link>$REPO_URL</link>
    <item>
      <title>XPaste $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown" xml:lang="zh-Hans"><![CDATA[$NOTES_ZH]]></description>
      <description sparkle:format="markdown" xml:lang="en"><![CDATA[$NOTES_EN]]></description>
      <enclosure url="$PREFIX/$NAME.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
  xmllint --noout "$DIST/appcast.xml"
fi

echo "完成："
du -h "$DIST/$NAME.zip"
cat "$DIST/$NAME.zip.sha256"
[[ -f "$DIST/appcast.xml" ]] && echo "appcast：$DIST/appcast.xml（构建号 $BUILD）"
true
