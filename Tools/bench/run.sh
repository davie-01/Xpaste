#!/bin/zsh
# M5 第 3 步的资源与性能测量，一条命令跑完（方案见 Docs/07 第 3 节）。
#
#   Tools/bench/run.sh            正式测量，约 4 小时；期间电脑不要有人用，面板会多次弹出并拿走键盘焦点
#   Tools/bench/run.sh --quick    几分钟的试跑，只检查脚本和各场景能不能跑通，数字不作结论
#   Tools/bench/run.sh idle scroll   只跑列出的场景（可与 --quick 合用）
#
# 用 Profile 构建（Release 优化 + BENCH 条件）。测量模式的数据在临时目录，偏好只用 com.mars.XPaste.bench，
# 采集和回放只读写命名剪贴板 com.mars.XPaste.bench，不碰真实的剪贴板、历史和设置。
# 结果在 build/bench/<时间>/：results.jsonl 每行一条结果，summary.txt 是汇总，env.txt 是环境，*.log 是原始输出。
#
# 可用环境变量调整：ROUNDS（空闲测量轮数，默认 3）、WARMUP_MIN（默认 2）、MEASURE_MIN（默认 15）。
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"

QUICK=0
typeset -a ONLY
for arg in "$@"; do
  case $arg in
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ONLY+=$arg ;;
  esac
done
wants() { (( ${#ONLY} == 0 )) || (( ${ONLY[(Ie)$1]} )) }

if (( QUICK )); then
  ROUNDS=${ROUNDS:-1}; WARMUP=${WARMUP:-2}; MEASURE=${MEASURE:-5}; ITEMS=1000
else
  ROUNDS=${ROUNDS:-3}; WARMUP=$(( ${WARMUP_MIN:-2} * 60 )); MEASURE=$(( ${MEASURE_MIN:-15} * 60 )); ITEMS=10000
fi

SUFFIX=""; (( QUICK )) && SUFFIX=-quick
OUT=build/bench/$(date +%Y%m%d-%H%M%S)$SUFFIX
mkdir -p "$OUT"
RESULTS=$OUT/results.jsonl
: > "$RESULTS"

echo "构建 Profile 配置…"
xcodegen generate >/dev/null
xcodebuild -project XPaste.xcodeproj -scheme XPaste -configuration Profile -derivedDataPath build/DerivedData build >"$OUT/build.log" 2>&1 \
  || { echo "构建失败，见 $OUT/build.log"; exit 1; }
APP=build/DerivedData/Build/Products/Profile/XPaste.app/Contents/MacOS/XPaste
WRITER=build/bench/pbwrite
swiftc -O Tools/bench/pbwrite.swift -o "$WRITER"

# 环境记录：07 第 3 节要求的版本、系统、硬件、供电、热状态、屏幕和后台负载。
{
  echo "commit: $(git rev-parse HEAD)"
  echo "工作区改动:"; git status --short
  echo; sw_vers
  echo; sysctl -n machdep.cpu.brand_string hw.model hw.memsize hw.ncpu
  echo; pmset -g batt; pmset -g therm 2>/dev/null || true
  echo; pmset -g | grep -iE "lowpowermode|powermode" || true
  echo; system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|UI Looks like|Main Display" || true
  echo; echo "同时运行的剪贴板相关进程:"; pgrep -lf -i "paste|clip" | grep -v -e pbwrite -e "$0" || echo "（无）"
  echo; echo "开始时的负载:"; uptime
  echo; top -l 2 -s 5 -n 5 -o cpu -stats pid,command,cpu,idlew,mem | tail -12
} >"$OUT/env.txt" 2>&1
if pgrep -x XPaste >/dev/null || pgrep -x Paste >/dev/null; then
  echo "注意：XPaste 或 Paste 正在运行，会影响空闲测量，已记入 env.txt。"
fi

# run_one <标签> [变量=值…]：跑一个场景，结果行加上标签追加到 results.jsonl。
run_one() {
  local label=$1; shift
  local log=$OUT/$label.log
  echo "$(date +%H:%M:%S) $label"
  if ! env "$@" XPASTE_BENCH_WRITER="$ROOT/$WRITER" "$APP" >"$log" 2>"$log.stderr"; then
    echo "  失败，见 $log"
  fi
  grep '^BENCH ' "$log" | sed "s/^BENCH {/{\"run\":\"$label\",/" >>"$RESULTS" || true
}

# B8 和 L46：在第一批和最后一批面板开关后停下，抓内存图和新增对象。
run_lifecycle() {
  local label=$1; shift
  local log=$OUT/$label.log hold=$OUT/hold-$label
  mkdir -p "$hold"
  echo "$(date +%H:%M:%S) $label"
  env "$@" XPASTE_BENCH_HOLD="$ROOT/$hold" "$APP" >"$log" 2>"$log.stderr" &
  local pid=$!
  for mark in panel-first panel-last; do
    while ! grep -q "\"label\":\"$mark\"" "$log" 2>/dev/null; do
      kill -0 $pid 2>/dev/null || break 2
      sleep 1
    done
    if [[ $mark == panel-first ]]; then
      leaks $pid --outputGraph="$hold/first.memgraph" >"$hold/leaks-first.txt" 2>&1 || true
    else
      leaks $pid --outputGraph="$hold/last.memgraph" >"$hold/leaks-last.txt" 2>&1 || true
      heap --sortBySize --diffFrom="$hold/first.memgraph" "$hold/last.memgraph" >"$hold/heap-new-since-first.txt" 2>&1 || true
      vmmap --summary $pid >"$hold/vmmap-last.txt" 2>&1 || true
    fi
    touch "$hold/continue-$mark"
  done
  wait $pid || echo "  失败，见 $log"
  grep '^BENCH ' "$log" | sed "s/^BENCH {/{\"run\":\"$label\",/" >>"$RESULTS" || true
}

# B1、B2、B12：空闲。四种配置交错跑，降低温度和后台任务的偏差。
if wants idle; then
  for round in $(seq 1 $ROUNDS); do
    run_one idle-empty-250-r$round   XPASTE_BENCH=idle XPASTE_BENCH_ITEMS=0        XPASTE_BENCH_INTERVAL=0.25 XPASTE_BENCH_WARMUP=$WARMUP XPASTE_BENCH_DURATION=$MEASURE
    run_one idle-10k-250-r$round     XPASTE_BENCH=idle XPASTE_BENCH_ITEMS=$ITEMS   XPASTE_BENCH_INTERVAL=0.25 XPASTE_BENCH_WARMUP=$WARMUP XPASTE_BENCH_DURATION=$MEASURE
    run_one idle-10k-500-r$round     XPASTE_BENCH=idle XPASTE_BENCH_ITEMS=$ITEMS   XPASTE_BENCH_INTERVAL=0.5  XPASTE_BENCH_WARMUP=$WARMUP XPASTE_BENCH_DURATION=$MEASURE
    run_one idle-10k-visible-r$round XPASTE_BENCH=idle XPASTE_BENCH_ITEMS=$ITEMS   XPASTE_BENCH_INTERVAL=0.25 XPASTE_BENCH_WARMUP=$WARMUP XPASTE_BENCH_DURATION=$MEASURE XPASTE_BENCH_PANEL=visible
  done
fi

# B3、B12：复制节奏，250 与 500 ms 轮询各一轮。
if wants cadence; then
  if (( QUICK )); then cadence=(XPASTE_BENCH_COUNT=20 XPASTE_BENCH_GAPS=100,500); else cadence=(XPASTE_BENCH_COUNT=200); fi
  run_one cadence-250 XPASTE_BENCH=cadence XPASTE_BENCH_INTERVAL=0.25 $cadence
  run_one cadence-500 XPASTE_BENCH=cadence XPASTE_BENCH_INTERVAL=0.5  $cadence
fi

if wants lifecycle; then
  if (( QUICK )); then
    run_lifecycle lifecycle XPASTE_BENCH=lifecycle XPASTE_BENCH_BATCHES=2 XPASTE_BENCH_CYCLES=50 XPASTE_BENCH_ITEMS=200
  else
    run_lifecycle lifecycle XPASTE_BENCH=lifecycle XPASTE_BENCH_BATCHES=5 XPASTE_BENCH_CYCLES=1000 XPASTE_BENCH_ITEMS=1000
  fi
fi

if wants retention; then
  if (( QUICK )); then run_one retention XPASTE_BENCH=retention XPASTE_BENCH_ITEMS=500 XPASTE_BENCH_KEEP=20
  else run_one retention XPASTE_BENCH=retention XPASTE_BENCH_ITEMS=10000 XPASTE_BENCH_KEEP=100; fi
fi

# V17：1 万条下的滚动，跑三轮。
if wants scroll; then
  for round in $(seq 1 $ROUNDS); do
    run_one scroll-r$round XPASTE_BENCH=scroll XPASTE_BENCH_ITEMS=$ITEMS XPASTE_BENCH_DURATION=$(( QUICK ? 3 : 20 ))
  done
fi

if wants search; then
  run_one search XPASTE_BENCH=search XPASTE_BENCH_ITEMS=$ITEMS XPASTE_BENCH_REPEATS=$(( QUICK ? 5 : 50 ))
fi

# L09、L28：大图预览、旋转、编码、抠图。
if wants image; then
  if (( QUICK )); then run_one image XPASTE_BENCH=image XPASTE_BENCH_SIZES=1000x800,2000x1500 XPASTE_BENCH_ITEMS=50
  else run_one image XPASTE_BENCH=image XPASTE_BENCH_SIZES=2000x1500,4000x3000,6000x4000,8000x6000; fi
fi

# L72：Stack 里的大内容。
if wants stack; then
  if (( QUICK )); then run_one stack XPASTE_BENCH=stack XPASTE_BENCH_TEXT_MB=1 XPASTE_BENCH_IMAGE_SIZES=1000x800
  else run_one stack XPASTE_BENCH=stack; fi
fi

# B10：音效开、关各起一个进程，突发复制后静置。开着的那一轮会真的出声。
if wants sound; then
  if (( QUICK )); then sound=(XPASTE_BENCH_COUNT=20 XPASTE_BENCH_WARMUP=2 XPASTE_BENCH_SETTLE=1,5); else sound=(XPASTE_BENCH_COUNT=100); fi
  run_one sound-off XPASTE_BENCH=sound XPASTE_BENCH_SOUND=0 $sound
  run_one sound-on  XPASTE_BENCH=sound XPASTE_BENCH_SOUND=1 $sound
fi

# V07：文字识别积压，截图大小的几百张和大图各一轮。
if wants ocr; then
  if (( QUICK )); then run_one ocr-small XPASTE_BENCH=ocr XPASTE_BENCH_IMAGES=20 XPASTE_BENCH_SIZE=1440x900 XPASTE_BENCH_PROBES=3 XPASTE_BENCH_ITEMS=200
  else
    run_one ocr-small XPASTE_BENCH=ocr XPASTE_BENCH_IMAGES=300 XPASTE_BENCH_SIZE=1440x900
    run_one ocr-large XPASTE_BENCH=ocr XPASTE_BENCH_IMAGES=100 XPASTE_BENCH_SIZE=4000x3000
  fi
fi

{ echo; echo "结束时的负载:"; uptime; pmset -g therm 2>/dev/null || true; } >>"$OUT/env.txt" 2>&1
python3 -I "$ROOT/Tools/bench/summarize.py" "$RESULTS" | tee "$OUT/summary.txt"
echo
echo "结果目录：$OUT"
