#!/bin/bash
# 影视盒 · 电视一键更新（Mac）
#
# 用法：
#   ./scripts/update-tv.sh <电视IP> [--no-pull] [--dry-run]
#   TV_IP=192.168.1.84 ./scripts/update-tv.sh        # 也可以走环境变量
#   --dry-run 只拉代码和编译，不碰电视（用于自检）
#
# 例子：
#   ./scripts/update-tv.sh 192.168.1.84
#
# 只做三件事：拉代码 → 编译 → 覆盖安装。不 force-stop、不启动 App、不碰电视当前画面。
#
# 首次使用要先做一次（脚本代替不了）：
#   1. 装 DevEco Studio，登录华为账号；
#   2. 让账号持有人在 AGC 里登记这台电视的 UDID（hdc shell bm get --udid）；
#   3. 用 DevEco 打开本工程，File > Project Structure > Signing Configs >
#      Automatically generate signature，签一次。签名配置会写进 build-profile.json5；
#   4. 电视开「开发者模式 + 无线调试」，跟电脑在同一个局域网，记下 IP。
#
# 之后每次升级：在仓库目录跑这一条命令即可。

set -euo pipefail

DEECO=/Applications/DevEco-Studio.app
# 允许用环境变量覆盖，方便 DevEco 装在非标准位置或做自检
HDC="${HDC_OVERRIDE:-$DEECO/Contents/sdk/default/openharmony/toolchains/hdc}"
HVIGORW="${HVIGORW_OVERRIDE:-$DEECO/Contents/tools/hvigor/bin/hvigorw}"
LOG=/tmp/tvbox-update-build.log

die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }

# ---------- 参数 ----------
TV_IP="${1:-${TV_IP:-}}"
NO_PULL=0
DRY_RUN=0
for arg in "${@:2}"; do
  case "$arg" in
    --no-pull) NO_PULL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) die "未知参数：$arg" ;;
  esac
done
[[ -n "$TV_IP" ]] || die "缺少电视 IP。用法：./scripts/update-tv.sh <电视IP> [--no-pull] [--dry-run]"

# ---------- 环境 ----------
[[ -d "$DEECO" ]] || die "没找到 DevEco Studio：$DEECO"
[[ -x "$HDC" ]]    || die "没找到 hdc：$HDC"
[[ -x "$HVIGORW" ]]|| die "没找到 hvigorw：$HVIGORW"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT 不是 git 仓库"

# ---------- 拉代码 ----------
# 自动签名会把签名配置写进根目录 build-profile.json5。这是本地配置，不入库。
# 拉代码前临时藏起来，拉完放回去；别的文件有改动就直接停，不替人做决定。
SIGN_FILES=(build-profile.json5 entry/build-profile.json5)
OTHER_DIRTY="$(git status --porcelain | grep -v -E '^.. (build-profile\.json5|entry/build-profile\.json5|scripts/|scripts/update-tv\.sh)$' || true)"
if [[ -n "$OTHER_DIRTY" ]]; then
  echo "$OTHER_DIRTY" >&2
  die "工作区还有其它改动，先提交或还原再跑。脚本不会替你丢改动。"
fi

if [[ "$NO_PULL" -eq 1 ]]; then
  ok "跳过拉代码（--no-pull）"
else
  STASHED=0
  if ! git diff --quiet -- "${SIGN_FILES[@]}"; then
    git stash push -q -m 'tvbox-update: local signing config' -- "${SIGN_FILES[@]}"
    STASHED=1
    ok "本地签名配置已暂时收起"
  fi
  git pull --ff-only || die "git pull 失败（可能有本地提交或远端分叉），自己处理后再跑"
  ok "代码已更新"
  if [[ "$STASHED" -eq 1 ]]; then
    git stash pop -q || die "签名配置恢复失败，手动 git stash list / git stash pop 处理"
    ok "本地签名配置已恢复"
  fi
fi

# ---------- 编译 ----------
# 按项目规矩：日志重定向到文件再 grep，别用 | head 截断（SIGPIPE 会把打包掐掉）。
echo "→ 编译中，日志：$LOG"
set +e
JAVA_HOME="$DEECO/Contents/jbr/Contents/Home" \
DEVECO_SDK_HOME="$DEECO/Contents/sdk" \
"$HVIGORW" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon \
  > "$LOG" 2>&1
BUILD_RC=$?
set -e
if [[ "$BUILD_RC" -ne 0 ]]; then
  grep -E "ERROR|BUILD" "$LOG" | tail -20 >&2 || true
  die "编译失败（exit ${BUILD_RC}），完整日志：$LOG"
fi
grep -E "BUILD" "$LOG" | tail -3 || true
ok "编译通过"

HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
if [[ ! -f "$HAP" ]]; then
  die "没有生成签名包：${HAP}。首次请按本文件开头的步骤在 DevEco 里做一次自动签名。"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  ok "dry-run：编译完成，不连接电视、不安装"
  exit 0
fi

# ---------- 静默推送 ----------
# hdc 每次外部调用会掉线，所以连接、查设备、安装必须在同一个进程里串完。
killall hdc 2>/dev/null || true
"$HDC" start -r >/dev/null 2>&1 || true
"$HDC" tconn "${TV_IP}:5555" >/dev/null 2>&1 || die "连不上 ${TV_IP}:5555，检查电视无线调试和 IP"

TARGETS="$("$HDC" list targets 2>/dev/null || true)"
if ! echo "$TARGETS" | grep -q "$TV_IP"; then
  echo "$TARGETS" >&2
  die "设备列表里没有 $TV_IP"
fi

echo "→ 覆盖安装（不启动 App）：$HAP"
"$HDC" -t "${TV_IP}:5555" install -r "$HAP" || die "安装失败，电视上可能弹了确认框，看一眼电视屏幕"
ok "已推送到 ${TV_IP}，电视当前画面未被打断"
