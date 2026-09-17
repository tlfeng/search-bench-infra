#!/bin/bash
# 在 rally 机上触发 esrally 压测，采集「耗时 + 体积 + 段数」证据，跑完归档到 OSS。
#
# 用法：
#   ./run-bench.sh --track geonames --challenge append-no-conflicts --clients 8 \
#                  --codec zstd-v3 --tag arch=arm --tag engine=ez --expected-nodes 2
#
# 说明：
#   - 目标地址取自 rally 机上的 /etc/es-targets.conf（由 userdata 写入）
#   - 每场 race 的报告文件名必须唯一，否则 esrally 会追加而不是覆盖
#   - 默认 detach（远端 setsid 起进程 + 本地轮询），压测跑几十分钟也不会被 ssh 断线掐死
#
# 关于 run-id 唯一性（并发场景下容易误判，实测过）：
#   run-id = <track>-<challenge>-<YYYYmmdd-HHMMSS>，由**远端** rally 机按自己时钟生成。
#   并发矩阵里多个栈的 bench 是同一秒启动的，所以**撞 run-id 是常态，不是意外**。
#   这不是 bug：隔离靠的是 results/<stack>/ 目录与 oss_prefix=<base>/<stack>，
#   同名 run-id 落在不同父目录下互不影响。真正会出问题的是"同一栈内同秒跑两场"，
#   那才是要避免的。别为了"让 run-id 全局唯一"去加随机数 —— 那会破坏按时间戳回溯。
#
# codec 注入原理（核对 esrally 2.12.0 源码，不是猜的）：
#   geonames 的 challenge 把 create-index 写成
#     "settings": {{index_settings | default({}) | tojson}}
#   而 esrally/track/params.py 的 CreateIndexParamSource 会把它 **merge 进**
#   index.json 的 body.settings（body["settings"].update(settings)），
#   所以用 track-param 就能改 codec —— 不用改 track 文件、不用重建镜像。
#
#   default           不注入，保持 track 原样
#   zstd / zstd-v2    {"index.codec":"ZSTD"}                    ez 的 CODEC_V2（纯 Java ZSTD，无字典）
#   zstd-v3           {"index.codec":"ZSTD",
#                      "index.compression.zstd.jni":true}       ez 的 CODEC_V3（native + 字典 + 子块 + 前缀压缩）
#   best-compression  {"index.codec":"best_compression"}        DEFLATE + 预置字典（上游语义）
#
#   注意两点：
#   1) "ZSTD" 必须大写 —— easysearch 的 CodecService 是 "ZSTD".equals(name) 精确匹配，
#      小写会走 SPI 名称查找并抛 failed to find codec [zstd]。
#   2) V2/V3 在建索引时定死（resolveZstdCodec 读 index.compression.zstd.jni），
#      而 jni=true 但 native 后端不可用时 V3 是**硬失败**，不会静默降级 —— 所以
#      起跑前必须冒烟（--smoke，默认开），否则可能白跑一轮。
set -euo pipefail

TRACK="geonames"
CHALLENGE="append-no-conflicts"
TRACK_PATH=""                       # 留空=自动探测本地 track（离线语料），找不到才回退联网
CLIENTS=""
CLIENTS_PARAM="bulk_indexing_clients"   # geonames 的并发参数名（**不是 clients**）
CODEC="default"
ENGINE_USER="admin"
ENGINE_PASS="${ENGINE_PASS:-Qwer@1234}"
TAGS=()
EXTRA_PARAMS=""
TEST_MODE=""      # --test-mode：极小数据集，秒级完成，只用于打通链路
DIST_VERSION=""   # --dist-version：告知 esrally 集群的真实血统（easysearch 必传）
EXPECTED_NODES="1"
MODE="detach"     # detach | foreground
SMOKE="1"         # 起跑前跑一场 --test-mode 冒烟

while [[ $# -gt 0 ]]; do
  case "$1" in
    --track) TRACK="$2"; shift 2;;
    --track-path) TRACK_PATH="$2"; shift 2;;
    --challenge) CHALLENGE="$2"; shift 2;;
    --clients) CLIENTS="$2"; shift 2;;
    --clients-param) CLIENTS_PARAM="$2"; shift 2;;
    --codec) CODEC="$2"; shift 2;;
    --expected-nodes) EXPECTED_NODES="$2"; shift 2;;
    --user) ENGINE_USER="$2"; shift 2;;
    --pass) ENGINE_PASS="$2"; shift 2;;
    --tag) TAGS+=("$2"); shift 2;;
    --track-params) EXTRA_PARAMS="$2"; shift 2;;
    --dist-version) DIST_VERSION="$2"; shift 2;;
    --test-mode) TEST_MODE="--test-mode"; shift 1;;
    --foreground) MODE="foreground"; shift 1;;
    --detach) MODE="detach"; shift 1;;
    --skip-smoke) SMOKE="0"; shift 1;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# LOCAL_DIR 由 Makefile 按 STACK 注入：default -> results/，其余 -> results/<stack>/。
# 两台 rally 机同时跑时产物各归各的目录，否则 fetch 会把它们混到一起。
LOCAL_DIR="${LOCAL_DIR:-$ROOT/results}"
mkdir -p "$LOCAL_DIR"

# ---------- codec → 索引设置 与 回读期望值（唯一事实来源） ----------
# 期望值用于跑完后的回读校验：写进去的 codec 与集群实际生效的不一致 = 这轮数据不可用。
CODEC_SETTINGS="{}"     # index_settings，注入 index body
CODEC_EXPECT=""         # 逗号分隔的 key=value，如 index.codec=ZSTD,index.compression.zstd.resolved_format=V3
CODEC_TAG="$CODEC"
case "$CODEC" in
  default|none|"")
    CODEC="default"; CODEC_SETTINGS="{}"; CODEC_EXPECT="";;
  zstd|zstd-v2)
    CODEC="zstd-v2"
    CODEC_SETTINGS='{"index.codec":"ZSTD"}'
    CODEC_EXPECT="index.codec=ZSTD";;
  zstd-v3)
    CODEC_SETTINGS='{"index.codec":"ZSTD","index.compression.zstd.jni":true}'
    # V3 是 resolveZstdCodec() 读 jni=true 后的结果，只读 + Final，可用于回读确证
    CODEC_EXPECT="index.codec=ZSTD,index.compression.zstd.resolved_format=V3";;
  best-compression)
    CODEC_SETTINGS='{"index.codec":"best_compression"}'
    CODEC_EXPECT="index.codec=best_compression";;
  *)
    echo "ERROR: 不认识的 --codec ${CODEC}（可选 default | zstd | zstd-v2 | zstd-v3 | best-compression）" >&2
    exit 1;;
esac
CODEC_TAG="$CODEC"

# 取 rally 机公网 IP 必须经 scripts/tf.sh：它会切到 STACK 对应的 workspace 再读 output。
# 直接调 terraform 会落到「当前 workspace」上 —— 多栈并存时可能压测跑到了另一套环境的机器上。
RALLY_IP=$("$HERE/tf.sh" output -raw rally_public_ip)
[ -n "$RALLY_IP" ] || { echo "取不到 rally_public_ip，先 make up STACK=${STACK:-default}" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
# 报告文件名/run-id 带 codec：同一 track 的 codec 对照场次不会互相覆盖
RUN_ID="${TRACK}-${CHALLENGE}"
[ "$CODEC" != "default" ] && RUN_ID="${RUN_ID}-${CODEC}"
RUN_ID="${RUN_ID}-${STAMP}"
# 供 timeit.sh / fetch 关联本次 run（bench 阶段结束时回填耗时用）
echo "$RUN_ID" > "$LOCAL_DIR/.last-run-id"

USER_TAGS=""
# esrally 的 --user-tags 必须是 key:value（冒号），多个之间逗号分隔。
# 命令行习惯写 --tag arch=x86（等号），这里统一转成冒号；否则 esrally 解析会报
# "not enough values to unpack (expected 2, got 1)" 并直接拒绝开跑。
for t in "${TAGS[@]}"; do USER_TAGS="${USER_TAGS}${t//=/:},"; done
USER_TAGS="${USER_TAGS}codec:${CODEC_TAG},run:${RUN_ID}"

# ---------- track-params ----------
# 必须整体作为一个 JSON 对象传给 esrally：--track-params 的解析是
#   utils/opts.py:to_dict → 先试 json.loads(arg)，失败才按 "k:v,k:v" 切分。
# 走 JSON 这条路，值里带逗号/花括号才不会把参数切碎（index_settings 的 JSON 正含逗号）。
TRACK_PARAMS="{}"
if command -v jq >/dev/null 2>&1; then
  if [ -n "$CLIENTS" ]; then
    TRACK_PARAMS=$(jq -c --arg k "$CLIENTS_PARAM" --argjson v "$CLIENTS" '. + {($k): $v}' <<<"$TRACK_PARAMS")
  fi
  if [ "$CODEC_SETTINGS" != "{}" ]; then
    TRACK_PARAMS=$(jq -c --argjson s "$CODEC_SETTINGS" '. + {index_settings: $s}' <<<"$TRACK_PARAMS")
  fi
  if [ -n "$EXTRA_PARAMS" ]; then
    TRACK_PARAMS=$(jq -c --argjson e "$(jq -Rn --arg s "$EXTRA_PARAMS" '$s | split(",") | map(split(":") | {(.[0]): (.[1]|tonumber? // .[1])}) | add // {}')" \
                   '. * $e' <<<"$TRACK_PARAMS")
  fi
else
  echo "ERROR: 需要 jq 组装 track-params（brew install jq）" >&2
  exit 1
fi
# 单引号会破坏远端脚本里的 TP='...' 赋值；我们的值只有数字/字母/JSON 标点，命中即报错而不是静默跑错。
case "$TRACK_PARAMS" in
  *"'"*) echo "ERROR: track-params 含单引号，无法安全传递：$TRACK_PARAMS" >&2; exit 1;;
esac

echo "=== 触发压测 ==="
echo "  rally   : $RALLY_IP"
echo "  track   : $TRACK ($CHALLENGE)"
echo "  clients : ${CLIENTS:-默认}  (参数名 ${CLIENTS_PARAM})"
echo "  codec   : $CODEC   settings=$CODEC_SETTINGS"
echo "  期望节点数: $EXPECTED_NODES"
echo "  run id  : $RUN_ID"
echo "  模式    : $MODE$([ "$SMOKE" = 1 ] && echo " + 起跑前冒烟(--test-mode)" || echo "（已跳过冒烟）")"

# 远端执行脚本
read -r -d '' REMOTE <<'EOS' || true
set -uo pipefail          # 不开 -e：压测中途即便出错，也必须把证据采集与归档跑完
source /etc/es-oss.conf
TARGETS=$(cat /etc/es-targets.conf)
ADMIN_PASS="${ADMIN_PASS:-__PASS__}"
RALLY_BIN=${RALLY_BIN:-/opt/esrally/bin/esrally}
RUN_ID="__RUN_ID__"
OUT="/data/rally/results/${RUN_ID}"
EXPECTED_NODES=__EXPECTED_NODES__
CODEC_NAME="__CODEC__"
CODEC_EXPECT="__CODEC_EXPECT__"
TRACK_NAME="__TRACK__"
# 这两个必须由本地侧注入到远端脚本里 —— 远端会引用 $TP/$CODEC_SETTINGS，
# 漏了注入时 set -u 直接报 "unbound variable" 并让整个脚本退出（只在 finalize 里
# 留下一堆空产物），症状是 rc=4 + 0 秒结束，很容易误判成 codec 不可用。
CODEC_SETTINGS='__CODEC_SETTINGS__'
TP='__TRACK_PARAMS__'
SERVER_LOG=/data/rally/logs/rally.log
mkdir -p "$OUT"

# ---------- 分阶段计时 ----------
# timing.tsv 是这轮压测的「各项时间」权威记录：
#   phase  起止时刻(HH:MM:SS)  耗时(s)  备注
# 与本地 results/timings.tsv（up/bench/fetch/down）合起来构成完整时间线。
START_ALL=$(date +%s)
printf 'phase\tstart\tend\telapsed_s\tnote\n' > "$OUT/timing.tsv"
PHASE_NAME=""; PHASE_T0=0
phase_begin() { PHASE_NAME="$1"; PHASE_T0=$(date +%s); echo "[$(date +%H:%M:%S)] ---- phase begin: $1"; }
phase_end() {
  local t1 el
  t1=$(date +%s); el=$(( t1 - PHASE_T0 ))
  printf '%s\t%s\t%s\t%s\t%s\n' "$PHASE_NAME" "$(date -d @$PHASE_T0 +%H:%M:%S)" "$(date -d @$t1 +%H:%M:%S)" "$el" "${1:-}" >> "$OUT/timing.tsv"
  echo "[$(date +%H:%M:%S)] ---- phase end  : $PHASE_NAME  ${el}s ${1:-}"
}

ES_BASE="${TARGETS%%,*}"                 # 首个节点做探针，health/settings 都是集群级
es_get() { curl -s -u "admin:${ADMIN_PASS}" "${ES_BASE}$1"; }
jval() { sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p" | tr -d '"' | head -1; }

# ---------- 退出钩子：无论怎么退出，都要采集证据 + 归档 ----------
FINALIZED=0
finalize() {
  local rc=$?
  [ "$FINALIZED" = 1 ] && return
  FINALIZED=1
  set +e

  phase_begin collect
  # 体积/段数/settings 一律**按索引**取，不要用 _all —— easysearch 的 _all 会算进
  # .security 系统索引（恒定 +8 段），段数与体积都会被污染。
  es_get "/_cluster/health?pretty"          > "$OUT/cluster-health-post.json"
  es_get "/_cat/nodes?v&h=name,ip,node.role,heap.percent,ram.percent,cpu,load_1m" > "$OUT/es-nodes.tsv"
  es_get "/${TRACK_NAME}/_settings?pretty"  > "$OUT/es-index-settings.json"
  es_get "/${TRACK_NAME}/_stats?pretty&filter_path=indices.*.primaries.docs,indices.*.primaries.store,indices.*.primaries.segments,indices.*.primaries.merges" > "$OUT/es-index-stats.json"
  es_get "/_cat/segments/${TRACK_NAME}?h=index,shard,segment,docs.count,size,size.memory&bytes=b&s=shard,segment" > "$OUT/es-segments.tsv"
  es_get "/_cat/modules?v&h=id,type"         > "$OUT/es-modules.txt"
  wc -l < "$OUT/es-segments.tsv"             > "$OUT/es-segment-count.txt"

  # codec 回读校验：写进去 != 实际生效 ⇒ 这轮数据不可用，必须显式报出来
  if [ -n "$CODEC_EXPECT" ]; then
    SETTINGS=$(cat "$OUT/es-index-settings.json")
    FAILS=0
    : > "$OUT/codec-verify.txt"
    IFS=',' read -ra EXPS <<< "$CODEC_EXPECT"
    for kv in "${EXPS[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"
      # 期望键是扁平写法（index.codec），但 ES/_settings 返回的是**嵌套** JSON：
      #   {"geonames":{"settings":{"index":{"codec":"ZSTD",...}}}}
      # 旧实现用 sed 找 "index.codec" 字面串，永远找不到 → 全部 FAIL → rc=4，
      # 一场跑了 83 分钟的好数据被误判成"codec 未生效"。
      # 这里按 . 拆路径逐层下钻（_settings 只查了单个索引，顶层即该索引）。
      got=$(printf '%s' "$SETTINGS" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
# _settings 返回 {<索引名>: {"settings": {"index": {...}}}}；这里只查了单个索引，
# 先下钻到 settings 层，期望键（index.codec）再从这一层开始逐层匹配。
vals = list(doc.values())
if len(vals) == 1 and isinstance(vals[0], dict) and "settings" in vals[0]:
    doc = vals[0]["settings"]
val = doc
for key in sys.argv[1].split("."):
    if isinstance(val, dict) and key in val:
        val = val[key]
    else:
        val = None
        break
print(val if val is not None else "")' "$k" 2>/dev/null)
      # python3 不可用时退回扁平串匹配（对嵌套结构会漏报，只作兜底）
      if [ -z "$got" ] && ! command -v python3 >/dev/null 2>&1; then
        got=$(echo "$SETTINGS" | tr -d ' ' | sed -n "s/.*\"${k}\":\"\([^\"]*\)\".*/\1/p")
      fi
      if [ "$(echo "$got" | tr 'A-Z' 'a-z')" = "$(echo "$v" | tr 'A-Z' 'a-z')" ]; then
        printf 'PASS %s expected=%s got=%s\n' "$k" "$v" "$got" >> "$OUT/codec-verify.txt"
      else
        printf 'FAIL %s expected=%s got=%s\n' "$k" "$v" "${got:-<未返回>}" >> "$OUT/codec-verify.txt"
        FAILS=$((FAILS + 1))
      fi
    done
    if [ "$FAILS" -gt 0 ]; then
      echo "!!!! codec 回读校验失败（$FAILS 项），本轮数据不可用："
      cat "$OUT/codec-verify.txt"
      rc=4
    else
      echo "codec 回读校验通过：$(tr '\n' ';' < "$OUT/codec-verify.txt")"
    fi
  fi
  phase_end "segments=$(cat "$OUT/es-segment-count.txt" 2>/dev/null)"

  phase_begin archive
  cd /data/rally/results || exit $rc
  tar czf "/tmp/${RUN_ID}.tar.gz" "$RUN_ID"
  if command -v ossutil64 >/dev/null 2>&1; then
    # 调试档 oss_bucket=unused-in-debug，归档失败不算致命（用 make fetch FROM=instance 取）
    if ossutil64 cp "/tmp/${RUN_ID}.tar.gz" "oss://${OSS_BUCKET}/${OSS_PREFIX}/${RUN_ID}.tar.gz" -f; then
      echo "archived -> oss://${OSS_BUCKET}/${OSS_PREFIX}/${RUN_ID}.tar.gz"
    else
      echo "WARN: OSS 归档失败（bucket=${OSS_BUCKET}），产物仍在实例上"
    fi
  else
    echo "WARN: ossutil64 未安装，产物仅留在实例上 /data/rally/results/${RUN_ID}"
  fi
  phase_end

  END_ALL=$(date +%s)
  printf 'TOTAL\t\t\t%s\t含就绪等待+冒烟+压测+采集+归档\n' "$(( END_ALL - START_ALL ))" >> "$OUT/timing.tsv"
  echo "==================================================="
  echo "各项时间（timing.tsv）："
  cat "$OUT/timing.tsv"
  echo "==================================================="
  exit "$rc"
}
trap finalize EXIT

echo "target-hosts: $TARGETS"
echo "expected nodes: $EXPECTED_NODES"

# 优先用离线语料（镜像烘焙）。国内 github/GCS 都拉不到，
# 走联网路径基本必失败，所以找不到本地 track 时给出明确警告而不是静默回退。
TRACK_LOCAL="/data/rally/benchmarks/tracks/__TRACK__"
TRACK_ARG="__TRACK_PATH__"
if [ -n "$TRACK_ARG" ]; then
  [ -d "$TRACK_ARG" ] || { echo "ERROR: 指定的 --track-path 不存在：$TRACK_ARG" >&2; exit 1; }
elif [ -d "$TRACK_LOCAL" ]; then
  TRACK_ARG="--track-path=$TRACK_LOCAL"
else
  echo "WARN: 本地无 track（${TRACK_LOCAL}），改用 --track=__TRACK__ 联网下载 —— 国内大概率失败"
  TRACK_ARG="--track=__TRACK__"
fi
echo "track     : $TRACK_ARG"

# 语料预检：文件缺失时 esrally 会去 GCS 下载并卡很久，提前报出来
DATA_DIR="/data/rally/benchmarks/data/__TRACK__"
if [ -d "$DATA_DIR" ]; then
  echo "corpus    : $(ls "$DATA_DIR" | tr '\n' ' ')"
else
  echo "WARN: 本地无语料目录 ${DATA_DIR}，esrally 将尝试联网下载"
fi

# 启动前环境指纹（与 perf-env-guard 对齐）
{
  echo "date=$(date -Is)"
  echo "kernel=$(uname -r)"
  echo "cpu=$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
  echo "cores=$(nproc)"
  echo "mem=$(free -g | awk '/Mem:/{print $2}')G"
  echo "turbo=$(cat /sys/devices/system/cpu/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo "thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
  echo "codec=$CODEC_NAME settings=$CODEC_SETTINGS"
  echo "run_id=$RUN_ID"
} | tee "$OUT/env-fingerprint.txt"
# 把实际生效的 track-params 存进产物目录，便于事后核对（不含密码）
echo "$TP" > "$OUT/track-params.json"

# ---------- phase: readiness —— 集群必须 green 且节点数够 ----------
# 单节点集群也会报 green，只看 green 会漏判集群发现失败，所以必须同时看 number_of_nodes。
phase_begin readiness
READY=0
for i in $(seq 1 90); do
  HEALTH=$(es_get "/_cluster/health" 2>/dev/null || true)
  STATUS=$(echo "$HEALTH" | jval status)
  NODES=$(echo "$HEALTH" | jval number_of_nodes)
  if [ "$STATUS" = "green" ] && [ "${NODES:-0}" -ge "$EXPECTED_NODES" ] 2>/dev/null; then READY=1; break; fi
  [ $((i % 6)) -eq 1 ] && echo "  等待集群就绪 ${i}/90：status=${STATUS:-?} nodes=${NODES:-?}"
  sleep 5
done
echo "$HEALTH" | tee "$OUT/cluster-health-prestart.json"
phase_end "status=${STATUS:-?} nodes=${NODES:-?}"
if [ "$READY" != 1 ]; then
  echo "ERROR: 集群未就绪（要 green 且 number_of_nodes >= ${EXPECTED_NODES}）" >&2
  exit 3
fi

# 集群健康采样：每 120s 记一行，用于事后区分「引擎慢」与「机器被回收/抖动」。
# 只取 health 与 nodes（元数据级，开销可忽略），起跑前启动、压测结束即停。
( while :; do
    echo "$(date -Is) $(es_get '/_cluster/health' | jval status) nodes=$(es_get '/_cluster/health' | jval number_of_nodes)"
    sleep 120
  done ) > "$OUT/cluster-watch.log" 2>&1 &
WATCH_PID=$!
echo "健康采样已启动 pid=${WATCH_PID}（每 120s 一行 -> cluster-watch.log）"

RACE_RC=1

# ---------- phase: smoke —— 用 --test-mode 先验一遍全链路 ----------
# 目标：codec 不可用 / track 拉不到 / 版本判定被拒 这些问题在 1 分钟内暴露，
# 而不是灌了 20 分钟数据之后才发现白跑。
if [ "__SMOKE__" = "1" ]; then
  phase_begin smoke-race
  "$RALLY_BIN" race \
    --pipeline=benchmark-only \
    --target-hosts="$TARGETS" \
    "$TRACK_ARG" \
    --challenge="__CHALLENGE__" \
    --client-options="basic_auth_user:'__USER__',basic_auth_password:'$ADMIN_PASS',verify_certs:false" \
    --track-params="$TP" \
    __DIST_VERSION__ \
    --test-mode \
    --user-tags="__USER_TAGS__" \
    --report-format=markdown \
    --report-file="$OUT/smoke-report.md" > "$OUT/smoke.log" 2>&1
  SMOKE_RC=$?
  phase_end "rc=$SMOKE_RC"
  if [ "$SMOKE_RC" != 0 ]; then
    echo "!!!! 冒烟失败（rc=${SMOKE_RC}），不进入正式轮次。最后 40 行："
    tail -40 "$OUT/smoke.log"
    echo "（要看全文：make ssh-rally 后 cat $OUT/smoke.log）"
    exit 5
  fi
  echo "冒烟通过：$(grep -o 'took [0-9]* seconds' "$OUT/smoke.log" | tail -1)"
else
  echo "已跳过冒烟（SKIP_SMOKE=1）"
fi

# ---------- phase: race ----------
# esrally 自己的日志（带毫秒时间戳）在 ~/.rally/logs/rally.log，它是「各任务耗时」的
# 唯一可解析来源（stdout 在非 tty 下只有寥寥几行 INFO）。先记偏移，跑完只取这一段的增量。
LOG_OFF=0
[ -f "$SERVER_LOG" ] && LOG_OFF=$(wc -c < "$SERVER_LOG" | tr -d ' ')
phase_begin race
"$RALLY_BIN" race \
  --pipeline=benchmark-only \
  --target-hosts="$TARGETS" \
  "$TRACK_ARG" \
  --challenge="__CHALLENGE__" \
  --client-options="basic_auth_user:'__USER__',basic_auth_password:'$ADMIN_PASS',verify_certs:false" \
  --track-params="$TP" \
  __DIST_VERSION__ \
  __TEST_MODE__ \
  --user-tags="__USER_TAGS__" \
  --report-format=markdown \
  --report-file="$OUT/report.md" 2>&1 | tee "$OUT/rally.log"
RACE_RC=${PIPESTATUS[0]}
phase_end "rc=$RACE_RC $(grep -o 'took [0-9]* seconds' "$OUT/rally.log" | tail -1)"

if [ -f "$SERVER_LOG" ]; then
  tail -c +$(( LOG_OFF + 1 )) "$SERVER_LOG" > "$OUT/esrally-server.log" 2>/dev/null || true
  echo "esrally 服务端日志增量：$(wc -l < "$OUT/esrally-server.log" | tr -d ' ') 行 -> esrally-server.log"
fi

# 停采样
kill "$WATCH_PID" 2>/dev/null || true

exit "$RACE_RC"
EOS

REMOTE=${REMOTE//__RUN_ID__/$RUN_ID}
# 先替换 __TRACK_PATH__ 再替换 __TRACK__，避免前缀互相干扰
REMOTE=${REMOTE//__TRACK_PATH__/$TRACK_PATH}
REMOTE=${REMOTE//__TRACK__/$TRACK}
REMOTE=${REMOTE//__CHALLENGE__/$CHALLENGE}
REMOTE=${REMOTE//__USER__/$ENGINE_USER}
REMOTE=${REMOTE//__PASS__/$ENGINE_PASS}
REMOTE=${REMOTE//__TRACK_PARAMS__/$TRACK_PARAMS}
REMOTE=${REMOTE//__CODEC__/$CODEC}
REMOTE=${REMOTE//__CODEC_EXPECT__/$CODEC_EXPECT}
REMOTE=${REMOTE//__CODEC_SETTINGS__/$CODEC_SETTINGS}
REMOTE=${REMOTE//__EXPECTED_NODES__/$EXPECTED_NODES}
REMOTE=${REMOTE//__SMOKE__/$SMOKE}
REMOTE=${REMOTE//__TEST_MODE__/$TEST_MODE}
# easysearch 自报版本 2.4.0，esrally 要求集群版本 >= 6.8.0；
# 用 --distribution-version 告知真实血统（easysearch 2.x 基于 ES 7.10.2）
if [ -n "$DIST_VERSION" ]; then
  REMOTE=${REMOTE//__DIST_VERSION__/--distribution-version=$DIST_VERSION}
else
  REMOTE=${REMOTE//__DIST_VERSION__/}
fi
REMOTE=${REMOTE//__USER_TAGS__/$USER_TAGS}

# 兜底自检：任何没被替换掉的 __X__ 都意味着远端会拿到**字面占位符**。
# 这类错的症状极难归因——远端 set -u 在用到未定义变量处退出，trap 仍把
# collect/archive 跑完，回传 rc=4 + 耗时 0 秒 + 一堆空产物，看起来像
# "codec 校验失败"，实际是脚本根本没开跑。宁可在这里 fail-fast。
# （__DONE__ 是本地轮询的哨兵，不在 REMOTE 里，不受影响。）
if printf '%s' "$REMOTE" | grep -q '__[A-Z][A-Z_]*__'; then
  echo "ERROR: 远端脚本仍有未替换的占位符（说明有值没注入，远端会跑出空产物）：" >&2
  printf '%s' "$REMOTE" | grep -o '__[A-Z][A-Z_]*__' | sort -u | sed 's/^/  /' >&2
  exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

# 等 SSH 真正可用再上传脚本。
# 为什么必须等：`make up` 返回时实例**刚被创建**，userdata（挂盘 / 装引擎 / 起服务）还在跑，
# sshd 可能还没 listen。一次性流水线（make run）从 up 直接进 bench 必然撞上
# `Connection refused` —— 而这个报错看起来像安全组/网络问题，实际只是"机器还没开机好"，
# 排查方向完全跑偏。远程脚本里虽然有集群就绪门禁，但它要 SSH 通了才跑得到。
SSH_WAIT_MAX=${SSH_WAIT_MAX:-600}
ssh_t0=$(date +%s)
ssh_i=0
while :; do
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 root@"$RALLY_IP" 'true' >/dev/null 2>&1; then
    echo "  SSH 就绪（等待 $(( $(date +%s) - ssh_t0 ))s）"
    break
  fi
  ssh_el=$(( $(date +%s) - ssh_t0 ))
  if [ "$ssh_el" -ge "$SSH_WAIT_MAX" ]; then
    echo "ERROR: 等待 SSH 就绪超时（${SSH_WAIT_MAX}s）：root@$RALLY_IP" >&2
    echo "  排查：安全组是否放行你的出口 IP（operator_cidr）、实例是否 Running" >&2
    exit 1
  fi
  ssh_i=$((ssh_i + 1))
  if [ $((ssh_i % 6)) -eq 1 ]; then
    echo "  等待 SSH 就绪 ${ssh_el}s / ${SSH_WAIT_MAX}s：$RALLY_IP"
  fi
  sleep 10
done

ssh "${SSH_OPTS[@]}" root@"$RALLY_IP" "cat > /tmp/run-bench-remote.sh" <<< "$REMOTE"

if [ "$MODE" = "foreground" ]; then
  RC=0
  ssh "${SSH_OPTS[@]}" root@"$RALLY_IP" "bash /tmp/run-bench-remote.sh" || RC=$?
else
  # setsid 起独立会话：压测跑几十分钟，ssh 一旦断线（或本机换网）不会把它掐死。
  # 退出码写进 /tmp/bench.rc，本地轮询这个文件判断是否结束。
  ssh "${SSH_OPTS[@]}" root@"$RALLY_IP" \
    "rm -f /tmp/bench.rc /tmp/bench.out; setsid bash -c 'bash /tmp/run-bench-remote.sh; echo \$? > /tmp/bench.rc' > /tmp/bench.out 2>&1 < /dev/null & sleep 1; echo launched"

  POLL_T0=$(date +%s); FAILS=0; LAST=""; N=0
  RC=1
  while :; do
    N=$((N + 1))
    LINE=$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes root@"$RALLY_IP" \
      'if [ -f /tmp/bench.rc ]; then echo "__DONE__ $(cat /tmp/bench.rc)"; else tail -n 1 /tmp/bench.out 2>/dev/null; fi' 2>/dev/null) || {
        FAILS=$((FAILS + 1))
        echo "  ! ssh 探测失败 ${FAILS}/5（rally 机可能已被竞价回收）"
        if [ "$FAILS" -ge 5 ]; then
          echo "ERROR: 连续 5 次 ssh 失败 —— 实例可能已被回收或销毁。用 make status / 阿里云控制台确认；产物若已归档可用 make fetch。" >&2
          exit 2
        fi
        sleep 20; continue
      }
    FAILS=0
    if [[ "$LINE" == __DONE__* ]]; then RC="${LINE##* }"; break; fi
    EL=$(( $(date +%s) - POLL_T0 ))
    if [ "$LINE" != "$LAST" ] || [ $((N % 20)) -eq 0 ]; then
      [ "$LINE" != "$LAST" ] && LAST="$LINE"
      printf '  [%s 累计 %dm%02ds] %s\n' "$(date +%H:%M:%S)" $((EL / 60)) $((EL % 60)) "$LINE"
    fi
    sleep 30
  done
  echo "远端已结束，rc=${RC}（远端总耗时 $(($(date +%s) - POLL_T0))s）"
fi

# 把远端的分阶段耗时拿回来直接打印（正式产物仍以 fetch 回来的为准）
TMP=$(mktemp)
if scp "${SSH_OPTS[@]}" -q "root@${RALLY_IP}:/data/rally/results/${RUN_ID}/timing.tsv" "$TMP" 2>/dev/null; then
  echo
  echo "=== 远端各项时间（timing.tsv）==="
  column -t -s $'\t' "$TMP" 2>/dev/null || cat "$TMP"
fi
rm -f "$TMP"

echo
if [ "$RC" = 0 ]; then
  echo "✅ 压测完成（rc=0）"
else
  echo "⚠️ 压测返回 rc=$RC —— 实例保留着，先看现场再决定是否销毁"
  echo "   看远端日志：make ssh-rally 然后 tail -50 /tmp/bench.out"
fi
echo "取回产物：  make fetch RUN_ID=$RUN_ID"
echo "多轮对照（不同 codec）记得每轮之间 make down，串行才省钱"
exit "$RC"
