#!/bin/zsh
# Audicap 构建+部署。
#
# 用固定的自签证书(不是 ad-hoc `-s -`):TCC 的 designated requirement 绑证书身份而非 cdhash,
# 改码重编不必每次重新授权「屏幕录制」。
#
# ★ 必须由你自己在终端跑:codesign 要访问登录钥匙串,非交互 shell(脚本/自动化工具)会挂死在授权框上。
#
# 2026-09-08 改:先在 staging 里编译+签名+校验,全部通过才替换安装位置。
# 旧脚本是先 cp 覆盖再签名,一旦钥匙串卡住或签名失败,~/Applications 里就留下一个签不上名、
# 权限失效、打不开的坏 app。
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/Audicap.app"
STAGE="$(mktemp -d)/Audicap.app"
# 扫目录而不是写死列表 —— 2026-09-08 加 Refine.swift 时就是忘了同步这里,
# 结果 deploy 编译失败(所幸 staging 机制挡住了,装着的 app 没被破坏)。
# 排除掉不属于 app 的独立工具(speechprobe 等评测探针)。
SRCS=(${(f)"$(ls *.swift | grep -vE '^(speechprobe|tap_probe|systap)\.swift$')"})
echo "源文件: ${SRCS[@]}"
BIN="AudicapApp"
SDK="$(xcrun --show-sdk-path)"
echo "SDK: $(xcrun --show-sdk-version) | swift: $(swiftc --version 2>/dev/null | head -1)"

SDKV="$(xcrun --show-sdk-version | cut -d. -f1)"
if [ "$SDKV" -lt 26 ]; then
  echo "✗ SDK $SDKV < 26,编不了 SpeechAnalyzer。先更新 CLT:"
  echo "  sudo softwareupdate -i 'Command Line Tools for Xcode 26.5'"
  exit 1
fi

echo "→ 编译 ${SRCS}…"
swiftc -O -sdk "$SDK" -o "$BIN" "${SRCS[@]}"

echo "→ 组 staging bundle…"
mkdir -p "$(dirname "$STAGE")"
if [ -d "$APP" ]; then
  cp -a "$APP" "$STAGE"
else
  # 第一次装(比如从仓库新克隆):用仓库里的 Info.plist 和图标组一个 bundle
  echo "  (没有现成的 $APP,用 bundle/Info.plist + AppIcon.icns 新建)"
  mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
  cp bundle/Info.plist "$STAGE/Contents/Info.plist"
  cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
  mkdir -p "$(dirname "$APP")"
fi
cp "$BIN" "$STAGE/Contents/MacOS/Audicap"
rm -rf "$STAGE/Contents/_CodeSignature"
xattr -cr "$STAGE"

# 签名身份放在专用钥匙串里(2026-09-26 起):登录钥匙串的密码和开机密码对不上时,
# codesign 会弹「输入 login 钥匙串密码」或直接 errSecInternalComponent,部署就卡死。
# 专用钥匙串的密码存在本机 ~/.config/audicap/sign-keychain-pass(600),这里自动解锁,
# 全程不弹框,非交互 shell 也能跑。没有这个钥匙串(比如别的机器)就退回登录钥匙串里的 AudicapDev。
SIGN_KC="$HOME/Library/Keychains/audicap-signing.keychain-db"
SIGN_PASS="$HOME/.config/audicap/sign-keychain-pass"
if [[ -f "$SIGN_KC" && -f "$SIGN_PASS" ]]; then
  IDENT="Audicap Signing"
  security unlock-keychain -p "$(cat "$SIGN_PASS")" "$SIGN_KC"
  KCARG=(--keychain "$SIGN_KC")
else
  IDENT="AudicapDev"; KCARG=()
fi
echo "→ 用 $IDENT 签名…"
codesign --force --deep -s "$IDENT" "${KCARG[@]}" --identifier com.kana.audicap "$STAGE"

echo "→ 校验…"
codesign -dvvv "$STAGE" 2>&1 | grep -iE "Identifier=|Authority=" | head -3
if ! codesign --verify --strict "$STAGE" 2>/tmp/cs_verify.err; then
  echo "✗ 签名校验失败(安装位置未动,现有 app 仍可用):"; cat /tmp/cs_verify.err
  echo "  (用登录钥匙串时若挂在授权框:点「始终允许」,再重跑)"
  exit 1
fi
AUTH="$(codesign -dvvv "$STAGE" 2>&1 | grep -i 'Authority=' | head -1)"
if [[ "$AUTH" != *"$IDENT"* ]]; then
  echo "✗ 没签成 $IDENT(当前: ${AUTH:-adhoc/无}),安装位置未动。私钥拿不到时会退化成 adhoc。"
  exit 1
fi

echo "→ 全部通过,替换安装位置…"
pkill -x Audicap 2>/dev/null || true
BAK="$APP.prev"
rm -rf "$BAK"; [ -d "$APP" ] && mv "$APP" "$BAK"
mv "$STAGE" "$APP"
echo "✓ 部署完成($AUTH)"
echo "  上一版留在 $BAK,出问题可以 rm -rf '$APP' && mv '$BAK' '$APP' 退回。"
echo "  权限异常时:tccutil reset ScreenCapture com.kana.audicap 后重开 app 重新授权。"
