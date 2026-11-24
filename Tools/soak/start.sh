#!/bin/zsh
# M5 第 4 步：24 小时长驻。用当前提交构建正式版，拷到 build/soak/ 里运行，再在后台起采样器。
# 正式版用自己的数据目录（~/Library/Application Support/XPaste）和偏好，期间照常使用电脑。
#
#   Tools/soak/start.sh          构建、启动 XPaste 和采样器
#   Tools/soak/start.sh sampler  只重新启动采样器，接着写当前这次的结果
#   Tools/soak/start.sh status   看采样器是否在 launchd 里、最后一行是什么时候
#   Tools/soak/start.sh stop     停掉采样器，记下睡眠与唤醒日志（XPaste 不退出）
#
# 采样期间写在 ~/Library/Logs/XPaste-Soak/<时间>/，stop 时拷回 build/soak/<时间>/：samples.csv 每分钟一行，env.txt 是环境，power.txt 是期间的睡眠与唤醒。
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"
APP=build/soak/XPaste.app
DATA="$HOME/Library/Application Support/XPaste"

LABEL=com.mars.XPaste.soak-sampler

# 采样器交给 launchd 托管，同一个 CSV 接着追加。
# launchd 起的程序默认读写不了“文稿”，所以采样器和它的输出放在 ~/Library/Logs 下，停止时拷回 $OUT。
# plist 放在 ~/Library/LaunchAgents：直接从别处 bootstrap 的服务在 2026-11-18 跑了 1 小时就被移除了，原因没查到；
# 放在这里，即使被移除，重新登录时也会自动装回。stop 时删掉。
LIVE_ROOT="$HOME/Library/Logs/XPaste-Soak"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
start_sampler() {
  local live="$LIVE_ROOT/${OUT:t}"
  mkdir -p "$live" "${PLIST:h}"
  cp build/soak/sampler "$LIVE_ROOT/sampler"
  [[ -f $OUT/samples.csv && ! -f $live/samples.csv ]] && cp "$OUT/samples.csv" "$live/samples.csv"
  local plist=$PLIST
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$LIVE_ROOT/sampler</string><string>$live/samples.csv</string>
    <string>$ROOT/$APP/Contents/MacOS/XPaste</string><string>$DATA</string><string>60</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$live/sampler.stderr</string>
</dict></plist>
EOF
  launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
  launchctl bootstrap gui/$UID "$plist"
}

if [[ ${1:-} == sampler ]]; then
  OUT=$(cat build/soak/current)
  start_sampler
  echo "采样器已重新启动，接着写 $LIVE_ROOT/${OUT:t}/samples.csv"
  exit 0
fi

if [[ ${1:-} == status ]]; then
  OUT=$(cat build/soak/current)
  launchctl print gui/$UID/$LABEL 2>/dev/null | grep -E "state =|pid =|last exit" || echo "launchd 里没有 $LABEL"
  echo "现在：$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "最后一行：$(tail -1 "$LIVE_ROOT/${OUT:t}/samples.csv")"
  exit 0
fi

if [[ ${1:-} == stop ]]; then
  OUT=$(cat build/soak/current)
  launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
  rm -f "$PLIST"
  cp "$LIVE_ROOT/${OUT:t}/"{samples.csv,sampler.stderr} "$OUT/"
  start=$(head -1 "$OUT/started")
  pmset -g log | awk -v s="$start" '$0 >= s' | grep -E "Sleep  |Wake  |DarkWake|Display is turned" >"$OUT/power.txt" || true
  { echo; echo "结束：$(date '+%Y-%m-%d %H:%M:%S')"; uptime; pmset -g therm 2>/dev/null || true; } >>"$OUT/env.txt"
  echo "已停止采样，结果在 $OUT"
  exit 0
fi

if pgrep -f "$ROOT/$APP/Contents/MacOS/XPaste" >/dev/null; then
  echo "长驻用的 XPaste 已在运行，先退出它再重新开始。"; exit 1
fi

xcodegen generate >/dev/null
xcodebuild -project XPaste.xcodeproj -scheme XPaste -configuration Release -derivedDataPath build/DerivedData build >build/soak/build.log 2>&1 \
  || { echo "构建失败，见 build/soak/build.log"; exit 1; }
rm -rf "$APP"
ditto build/DerivedData/Build/Products/Release/XPaste.app "$APP"
swiftc -O Tools/soak/sampler.swift -o build/soak/sampler

OUT=build/soak/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
echo "$OUT" >build/soak/current
date '+%Y-%m-%d %H:%M:%S' >"$OUT/started"
{
  echo "commit: $(git rev-parse HEAD)"
  echo "工作区改动:"; git status --short
  echo; sw_vers
  echo; sysctl -n machdep.cpu.brand_string hw.model hw.memsize
  echo; pmset -g batt; pmset -g therm 2>/dev/null || true
  echo; echo "同时运行的剪贴板相关进程:"; pgrep -lf -i "paste|clip" | grep -v -e sampler -e "$0" || echo "（无）"
  echo; echo "开始：$(date '+%Y-%m-%d %H:%M:%S')"; uptime
} >"$OUT/env.txt" 2>&1

open "$APP"
start_sampler
echo "已启动，结果在 $OUT"
