#!/bin/zsh
# Audicap 发布打包:给「其他人」用的可分发 app,全程不碰钥匙串。
#
# 和 deploy.sh 的区别:
# - deploy.sh 用 AudicapDev 自签证书装到本机 ~/Applications——签名身份稳定,
#   TCC 的「屏幕录制」授权跟着身份走,不用每次重新申请;但 codesign 要访问
#   登录钥匙串,只能在你自己的终端里手动跑。
# - release.sh 是打包给别人用的:对方机器上没有 AudicapDev 这张证书,只能
#   ad-hoc 签名(`-s -`)。ad-hoc 不碰钥匙串,可以在非交互 shell / CI 里跑;
#   代价是没有稳定身份,每次二进制一变 cdhash 就变,对方每次更新说不定都要
#   重新点一遍「仍要打开」——这一点写进了 README 提醒用户。
set -e
cd "$(dirname "$0")"

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "用法: ./release.sh <版本号>   例如: ./release.sh 0.1.0"
  exit 1
fi

BUILD="$(pwd)/build"
APP="$BUILD/Audicap.app"
ZIP="$BUILD/Audicap-${VERSION}-macOS26-arm64.zip"

# 源文件集合和 deploy.sh 保持一致:扫目录而不是写死列表,避免两边脚本
# 因为忘记同步而编出不一样的东西。排除掉不属于 app 的独立评测探针。
SRCS=(${(f)"$(ls *.swift | grep -vE '^(speechprobe|tap_probe|systap)\.swift$')"})
echo "源文件: ${SRCS[@]}"
BIN="$BUILD/AudicapApp"
SDK="$(xcrun --show-sdk-path)"
echo "SDK: $(xcrun --show-sdk-version) | swift: $(swiftc --version 2>/dev/null | head -1)"

SDKV="$(xcrun --show-sdk-version | cut -d. -f1)"
if [ "$SDKV" -lt 26 ]; then
  echo "✗ SDK $SDKV < 26,编不了 SpeechAnalyzer。先更新 CLT:"
  echo "  sudo softwareupdate -i 'Command Line Tools for Xcode 26.5'"
  exit 1
fi

echo "→ 清理 build/ …"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 编译(-O,当前机器架构 arm64)…"
# 只编当前机器所在的架构(arm64),不生成 universal binary。要支持 Intel 的话,
# 需要对每个架构分别加 -target arm64-apple-macos26 / -target x86_64-apple-macos26
# 编译出两份二进制,再用 `lipo -create a b -output out` 合成一个 fat binary——
# 这里先不做:没有 Intel 机器可测,合出来的东西没法验证能不能跑。
swiftc -O -sdk "$SDK" -o "$BIN" "${SRCS[@]}"

echo "→ 组 app bundle…"
# 版本号写进 staged 的 Info.plist,绝不直接改仓库里的 bundle/Info.plist——
# 那份是模板,写死版本号会导致下次改了忘记改回来,或者 git diff 里全是噪音。
STAGED_PLIST="$BUILD/Info.plist"
cp bundle/Info.plist "$STAGED_PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGED_PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$STAGED_PLIST"
cp "$STAGED_PLIST" "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Audicap"

# 去掉编译/复制过程中可能带上的 quarantine 等扩展属性,签名前先清干净。
xattr -cr "$APP"

echo "→ ad-hoc 签名(不用私钥,不碰钥匙串)…"
codesign --force --deep -s - --identifier com.kana.audicap "$APP"

echo "→ 校验签名…"
codesign --verify --strict "$APP"
echo "✓ 签名校验通过(ad-hoc,adhoc/无 Authority 是预期结果,不是错误)"

echo "→ 打包成 zip…"
ditto -c -k --keepParent "$APP" "$ZIP"

SIZE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo ""
echo "✓ 完成"
echo "  文件: $ZIP"
echo "  大小: $SIZE"
echo "  SHA256: $SHA"
