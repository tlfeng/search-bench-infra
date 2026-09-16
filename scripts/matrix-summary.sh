#!/bin/bash
# 把并行矩阵各栈的 esrally 报告汇总成一张对照表（summary.md）。
#
# 设计取舍：这里只做**机械汇总**，不下结论。
# 并发跑出来的两组数字并排放在一起，很容易被读成"谁更快"，但那要先确认环境一致性
# （可用区是否错开、rally 是否先饱和、error rate 是否为 0）。所以脚本只负责：
# 把该并排的数字并排，把该提醒的口径写在最上面。
#
# 用法：
#   matrix-summary.sh --matrix-dir results/_matrix/<ts> --stacks "x a"
#   matrix-summary.sh --stacks x,a --out /tmp/s.md
#
# 产物发现规则（与 Makefile 的 LOCAL_DIR 规则一致）：
#   stack=default -> results/        其余 -> results/<stack>/
#   优先读该目录下的 .last-run-id；没有就取最新的 run 目录；只有 .tar.gz 就解开。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

MATRIX_DIR=""
STACKS=""
OUT=""
TITLE="并行压测矩阵对照"

while [ $# -gt 0 ]; do
  case "$1" in
    --matrix-dir) MATRIX_DIR="$2"; shift 2;;
    --stacks) STACKS="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --title) TITLE="$2"; shift 2;;
    # help 取自文件头的注释块。不能硬编码行号（sed -n '2,18p'）：
    # 注释一改长就会把源码一起打印出来。这里打印开头连续的 # 行，遇到第一行真代码就停。
    -h|--help) awk 'NR>1{ if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next }
                     if ($0 ~ /^[[:space:]]*$/) next; exit }' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[ -n "$STACKS" ] || { echo "ERROR: 需要 --stacks \"x a\"（或 x,a）" >&2; exit 1; }
STACKS="$(echo "$STACKS" | tr ',' ' ')"
if [ -z "$MATRIX_DIR" ] || [ ! -d "$MATRIX_DIR" ]; then MATRIX_DIR="$ROOT/results/_matrix"; fi
[ -n "$OUT" ] || OUT="$MATRIX_DIR/summary.md"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/sbi-summary.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT INT TERM

# stack 名允许含 "-"（terraform 的 validation 就是这么定的），但拼进变量名必须换掉，
# 否则 eval "PLAN_x-y=..." 会被 shell 当成一条外部命令。
var_safe() { printf '%s' "$1" | tr '.-' '__'; }

local_dir_of() { # $1=stack
  if [ "$1" = "default" ]; then printf '%s' "$ROOT/results"; else printf '%s' "$ROOT/results/$1"; fi
}

# ---- 找每个栈最新的 run 目录 ----
find_run_dir() { # $1=stack -> stdout: run 目录；找不到返回 1
  local d; d="$(local_dir_of "$1")"
  if [ ! -d "$d" ]; then return 1; fi
  local rid=""
  if [ -f "$d/.last-run-id" ]; then rid="$(cat "$d/.last-run-id" 2>/dev/null)"; fi

  if [ -n "$rid" ] && [ -d "$d/$rid" ]; then printf '%s' "$d/$rid"; return 0; fi
  # 只有归档、还没解开的情况（make fetch 走 OSS 就是这条）
  if [ -n "$rid" ] && [ -f "$d/$rid.tar.gz" ]; then
    ( cd "$d" && tar xzf "$rid.tar.gz" ) >/dev/null 2>&1 || true
    if [ -d "$d/$rid" ]; then printf '%s' "$d/$rid"; return 0; fi
  fi

  # 兜底：取目录下最新的 run（形如 <track>-<challenge>[-<codec>]-<YYYYmmdd-HHMMSS>）
  local newest=""
  newest="$(find "$d" -maxdepth 1 -mindepth 1 -type d \
              -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' \
              2>/dev/null | sort | tail -1)"
  if [ -n "$newest" ]; then printf '%s' "$newest"; return 0; fi
  return 1
}

# esrally 的 markdown 报告 → 规范 TSV：metric \t task \t value \t unit
# 一台一次地算好落盘再用，别每取一个指标就重解析一遍：
# 那样既慢，又会让下游 awk 的 exit 提前关管道、在上游报 i/o error。
normalize_report() { # $1=report.md -> $2=输出 TSV
  awk -F'|' '
    /^\|/ {
      m=$2; t=$3; v=$4; u=$5
      gsub(/^[ \t]+|[ \t]+$/, "", m); gsub(/^[ \t]+|[ \t]+$/, "", t)
      gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", u)
      if (m == "" || m == "Metric" || m ~ /^-+$/) next
      print m "\t" t "\t" v "\t" u
    }' "$1" > "$2"
}

# $1=规范 TSV 文件 $2=metric $3=task(可空)
# 注意 "$3" 要写成 ${3:-}：脚本开了 set -u，只传两个参数时 $3 是未定义。
mval() {
  awk -F'\t' -v m="$2" -v t="${3:-}" \
    '($1 == m) && (t == "" || $2 == t) { print $3; exit }' "$1" 2>/dev/null
}
finger() { # $1=run dir $2=字段
  if [ ! -f "$1/env-fingerprint.txt" ]; then return 0; fi
  sed -n "s/^$2=//p" "$1/env-fingerprint.txt" | head -1
}

# ---- 收集 ----
S_NAMES=""
S_DIRS=""
S_TSV=""
for s in $STACKS; do
  d="$(find_run_dir "$s" 2>/dev/null || true)"
  sv="$(var_safe "$s")"
  tsv="$TMPD/m-$sv.tsv"
  : > "$tsv"
  if [ -n "$d" ] && [ -f "$d/report.md" ]; then normalize_report "$d/report.md" "$tsv"; fi
  S_NAMES="$S_NAMES $s"
  S_DIRS="$S_DIRS ${d:--}"
  S_TSV="$S_TSV $tsv"
  eval "PLANV_$sv=''"
  if [ -f "$MATRIX_DIR/plan.tsv" ]; then
    eval "PLANV_$sv=\"\$(awk -F'\t' -v s='$s' '\$1 == s {print; exit}' "$MATRIX_DIR/plan.tsv")\""
  fi
done
S_NAMES="${S_NAMES# }"
S_DIRS="${S_DIRS# }"
S_TSV="${S_TSV# }"

nth() { echo "$1" | awk -v k="$2" '{ print $k }'; }
dir_of()  { local v; v="$(nth "$S_DIRS" "$1")"; [ "$v" = "-" ] && v=""; printf '%s' "$v"; }
tsv_of()  { nth "$S_TSV" "$1"; }
name_of() { nth "$S_NAMES" "$1"; }
n_stacks() { echo "$S_NAMES" | wc -w | tr -d ' '; }
NS="$(n_stacks)"

plan_field() { # $1=stack $2=列号
  local sv; sv="$(var_safe "$1")"
  eval "row=\${PLANV_$sv:-}"
  if [ -z "$row" ]; then return 0; fi
  printf '%s' "$row" | awk -F'\t' -v c="$2" '{ print $c }'
}

# 表头：4 列固定 + 每栈一列。手动拼串而不靠 printf 里的嵌套替换 ——
# 嵌套写法很容易在列数上多出一个竖线，而 Markdown 表头错位会让整张表渲染不出来。
N1="$(name_of 1)"
N2="$(name_of 2)"
[ -n "$N2" ] || N2="—"
hdr_metric() {
  local h="| 指标 |" k=1
  while [ "$k" -le "$NS" ]; do h="$h $(name_of "$k") |"; k=$((k + 1)); done
  echo "$h 方向 | 比值 $N1/$N2 |"
}
hdr_sep() {
  local h="|---|" k=1
  while [ "$k" -le "$NS" ]; do h="$h---|"; k=$((k + 1)); done
  echo "$h---|---|"
}
hdr_task() {
  local h="| task |" k=1
  while [ "$k" -le "$NS" ]; do h="$h $(name_of "$k") |"; k=$((k + 1)); done
  echo "$h 比值 $N1/$N2 |"
}
hdr_task_sep() {
  local h="|---|" k=1
  while [ "$k" -le "$NS" ]; do h="$h---|"; k=$((k + 1)); done
  echo "$h---|"
}

row_cells() { # $1..=每栈的取值；输出 " v1 | v2 |"
  local r="" v
  for v in "$@"; do r="$r ${v:-—} |"; done
  printf '%s' "$r"
}
ratio() { # $1 $2 → 比值（第二个为 0 或空时给 n/a / —）
  local a="$1" b="$2"
  if [ -z "$a" ] || [ -z "$b" ]; then echo "—"; return; fi
  awk -v x="$a" -v y="$b" 'BEGIN{ if (y+0 == 0) print "n/a"; else printf "%.3f", x/y }'
}

mkdir -p "$(dirname "$OUT")"

{
echo "# $TITLE"
echo
echo "> **口径声明（先读这条）**"
echo ">"
echo "> 本表来自**并发**运行的多套环境，只用于 stack 之间的**相对比较**。"
echo "> 并发的价值是消掉跨时段漂移（这正是它相对串行四轮的意义），但同地域的多套实例"
echo "> 仍共享 ESSD 后端带宽与内网路径。因此："
echo ">"
echo "> 1. **各栈的绝对值不与历史单栈数据直接比**，只与「同时段、同 stack」的历史比；"
echo "> 2. 读差异前先确认：可用区是否错开、rally 是否先饱和、error rate 是否为 0；"
echo "> 3. 正式出报告的轮次仍应串行（见 README 2.8）。"
echo

echo "## 1. 环境"
echo
printf '| stack | profile | engine | zone | 网段 | CPU | 核 | 内存 | run-id |\n'
printf '|---|---|---|---|---|---|---|---|---|\n'
k=1
while [ "$k" -le "$NS" ]; do
  s="$(name_of "$k")"; d="$(dir_of "$k")"
  rid=""; if [ -n "$d" ]; then rid="$(basename "$d")"; fi
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$s" "$(plan_field "$s" 2)" "$(plan_field "$s" 3)" "$(plan_field "$s" 4)" "$(plan_field "$s" 5)" \
    "${d:+$(finger "$d" cpu)}" "${d:+$(finger "$d" cores)}" "${d:+$(finger "$d" mem)}" \
    "${rid:-（无产物）}"
  k=$((k + 1))
done
echo
echo "本次解析出的完整配置留档：\`$(basename "$MATRIX_DIR")/plan.tsv\`。"
echo

echo "## 2. 引擎侧关键指标"
echo
echo "\`↑\` 越大越好，\`↓\` 越小越好；\`比值\` = 第 1 栈 ÷ 第 2 栈。"
echo
# 三列用 | 当分隔符：用 tab 的话中间的空字段会让 read 把最后两段并成一个，
# 结果是"方向"和"单位"被粘在同一个变量里。
METRICS='Mean Throughput|index-append|↑|docs/s
Store size||↓|GB
Segment count||↓|—
Cumulative indexing time of primary shards||↓|min
Cumulative merge time of primary shards||↓|min
Cumulative merge count of primary shards||↓|—
Cumulative refresh count of primary shards||↓|—
Cumulative flush count of primary shards||↓|—
50th percentile latency|index-append|↓|ms
100th percentile latency|index-append|↓|ms
Total Young Gen GC time||↓|s
Total Old Gen GC count||↓|—'
echo "$(hdr_metric)"
echo "$(hdr_sep)"
echo "$METRICS" | while IFS='|' read -r metric task dir unit; do
  [ -n "${metric:-}" ] || continue
  vals=""
  any=0
  k=1
  while [ "$k" -le "$NS" ]; do
    v="$(mval "$(tsv_of "$k")" "$metric" "$task")"
    if [ -n "$v" ]; then any=1; fi
    vals="$vals $v"
    k=$((k + 1))
  done
  if [ "$any" = 0 ]; then continue; fi
  v1="$(echo "$vals" | awk '{print $1}')"
  v2="$(echo "$vals" | awk '{print $2}')"
  # shellcheck disable=SC2086
  printf '| %s (%s) |%s %s | %s |\n' "$metric" "${unit:-—}" "$(row_cells $vals)" "$dir" "$(ratio "$v1" "$v2")"
done
echo
echo "**读法提醒**：geonames 的搜索任务默认单并发（\`clients\` 只在写入侧），"
echo "所以查询侧吞吐在这里是延迟类指标，不代表并发吞吐上限。"
echo

echo "## 3. 各 task 中位吞吐（ops/s）"
echo
tasks=""
k=1
while [ "$k" -le "$NS" ]; do
  t="$(awk -F'\t' '$1 == "Median Throughput" && $2 != "" { print $2 }' "$(tsv_of "$k")" 2>/dev/null || true)"
  tasks="$tasks $t"
  k=$((k + 1))
done
tasks="$(echo "$tasks" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')"
if [ -z "$(echo "$tasks" | tr -d ' ')" ]; then
  echo "（无查询任务指标）"
else
  echo "$(hdr_task)"
  echo "$(hdr_task_sep)"
  for t in $tasks; do
    vals=""; any=0; k=1
    while [ "$k" -le "$NS" ]; do
      v="$(mval "$(tsv_of "$k")" "Median Throughput" "$t")"
      if [ -n "$v" ]; then any=1; fi
      vals="$vals $v"
      k=$((k + 1))
    done
    if [ "$any" = 0 ]; then continue; fi
    v1="$(echo "$vals" | awk '{print $1}')"
    v2="$(echo "$vals" | awk '{print $2}')"
    # shellcheck disable=SC2086
    printf '| %s |%s %s |\n' "$t" "$(row_cells $vals)" "$(ratio "$v1" "$v2")"
  done
fi
echo

echo "## 4. 一致性自检（决定这组数字能不能用）"
echo
printf '| stack | error rate | 核 | 段数 | 远端总耗时 |\n'
printf '|---|---|---|---|---|\n'
k=1
while [ "$k" -le "$NS" ]; do
  s="$(name_of "$k")"; d="$(dir_of "$k")"
  if [ -z "$d" ]; then
    printf '| %s | （无产物） | | | |\n' "$s"; k=$((k + 1)); continue
  fi
  # error rate 全为 0 时 m 从头到尾都没被赋值（0 > "" 恒假），必须用 seen 标记区分
  # "没看到该指标" 与 "看到了且是 0" —— 后者恰恰是我们最想看到的健康信号。
  er="$(awk -F'\t' '$1 == "error rate" { if (!seen || $3+0 > m) { m = $3+0; seen = 1 } }
                    END { if (!seen) print "—"; else print m }' "$(tsv_of "$k")")"
  seg="$(mval "$(tsv_of "$k")" "Segment count")"
  el=""
  if [ -f "$d/timing.tsv" ]; then
    el="$(awk -F'\t' '$1 == "TOTAL" { print $4 "s" }' "$d/timing.tsv" | head -1)"
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$s" "$er" "$(finger "$d" cores)" "$seg" "${el:-—}"
  k=$((k + 1))
done
echo
echo "**error rate 不全为 0 就不要读吞吐** —— 那说明有请求失败，数字没有意义。"
echo
echo "逐栈完整产物：\`results/<stack>/<run-id>/\`（report.md / es-index-stats.json /"
echo "es-segments.tsv / codec-verify.txt / timing.tsv / cluster-watch.log）。"
echo "矩阵运行日志：\`$(basename "$MATRIX_DIR")/<stack>.log\`。"
} > "$OUT"

echo "  汇总已写入：$OUT"
