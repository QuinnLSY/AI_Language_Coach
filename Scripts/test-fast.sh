#!/bin/zsh
# AI Language Coach — 快速测试入口
#
# 用法:
#   Scripts/test-fast.sh                 # 日常档：渲染并行 + 单测串行（全量 ~18min → ~4min）
#   Scripts/test-fast.sh --full          # 连 Ollama 真机组一起跑（+~50s）
#   Scripts/test-fast.sh --workers 6     # 改并行档（默认 10；本机 10 核实测最快）
#   Scripts/test-fast.sh --serial        # 全串行（排查偶发 / 对照基线时用）
#   Scripts/test-fast.sh --filter Xxx    # 只跑某一组（正则，透传给 swift test）
#
# 为什么拆成两截跑:
#   ① RenderTests 各用例互相独立（各自建窗口、各自 :memory: 库）→ 并行安全。
#      本机 10 核实测：823.7s → 151s，0 失败。⚠️ 12 worker 反而更慢（169s）
#      且会把带 3s 超时的轮询用例饿死，所以别一味加档。
#   ② AILanguageCoachTests 有 8 个类共写 `UserDefaults.standard`
#      （快捷键绑定表 / 通勤开关等）。并行 worker 是**独立进程却共用同一个 plist**，
#      实测 8 worker 红 8 条 —— 所以这一截保持串行，等那些类改成按用例隔离后再放开。
#   ③ OllamaIntegrationTests 默认整组 skip：本机 Ollama 在跑时会**真推理** 48.5s，
#      而日常回归要的是接线对不对。要验真机时加 --full（或手动设 ALC_RUN_OLLAMA_TESTS=1）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORKERS=10
FULL=0
SERIAL=0
FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)    FULL=1; shift ;;
    --serial)  SERIAL=1; shift ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --filter)  FILTER="$2"; shift 2 ;;
    *) echo "未知参数: $1（可用 --full / --serial / --workers N / --filter 正则）" >&2; exit 2 ;;
  esac
done

# ⚠️ 必须显式关掉：sandbox 会让 manifest 编译直接失败（sandbox_apply: Operation not permitted）。
SWIFT=(swift test --disable-sandbox)

# 默认不让 Ollama 真机组上场；--full 时才开。
export ALC_RUN_OLLAMA_TESTS=0
[[ $FULL -eq 1 ]] && export ALC_RUN_OLLAMA_TESTS=1

TOTAL_START=$SECONDS

run_group() {
  local label="$1"; shift
  print -r -- "── $label"
  local t0=$SECONDS
  "$@"
  print -r -- "── $label 完成（$((SECONDS - t0))s）"
}

if [[ $SERIAL -eq 1 ]]; then
  # 全串行：一个进程跑完两个 target（对照基线 / 排查偶发）。
  run_group "全量串行" $SWIFT ${FILTER:+--filter "$FILTER"}
else
  # 第一截：渲染测试并行。各用例独立，10 worker 实测 0 失败。
  run_group "RenderTests 并行 ($WORKERS worker)" \
    $SWIFT --parallel --num-workers "$WORKERS" ${FILTER:+--filter "$FILTER"} --filter RenderTests
  # 第二截：单测串行。UserDefaults.standard 跨进程串味，见文件头 ②。
  run_group "AILanguageCoachTests 串行" \
    $SWIFT ${FILTER:+--filter "$FILTER"} --filter AILanguageCoachTests
fi

print -r -- ""
print -r -- "全部完成，总耗时 $((SECONDS - TOTAL_START))s"
[[ $FULL -eq 0 ]] && print -r -- "（Ollama 真机组已跳过；要跑加 --full）"
