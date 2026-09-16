#!/bin/bash
# 在 rally 机上触发 esrally 压测，跑完把结果归档到 OSS。
#
# 用法：
#   ./run-bench.sh --track geonames --challenge append-no-conflicts --clients 8 \
#                  --tag arch=x86 --tag engine=es
#
# 说明：
#   - 目标地址取自 rally 机上的 /etc/es-targets.conf（由 userdata 写入）
#   - 每场 race 的报告文件名必须唯一，否则 esrally 会追加而不是覆盖
set -euo pipefail

TRACK="geonames"
CHALLENGE="append-no-conflicts"
TRACK_PATH=""                       # 留空=自动探测本地 track（离线语料），找不到才回退联网
CLIENTS=""
CLIENTS_PARAM="bulk_indexing_clients"   # geonames 的并发参数名（**不是 clients**）
ENGINE_USER="admin"
ENGINE_PASS="${ENGINE_PASS:-Qwer@123}"
TAGS=()
EXTRA_PARAMS=""
TEST_MODE=""      # --test-mode：极小数据集，秒级完成，只用于打通链路
DIST_VERSION=""   # --dist-version：告知 esrally 集群的真实血统（easysearch 必传）

while [[ $# -gt 0 ]]; do
  case "$1" in
    --track) TRACK="$2"; shift 2;;
    --track-path) TRACK_PATH="$2"; shift 2;;
    --challenge) CHALLENGE="$2"; shift 2;;
    --clients) CLIENTS="$2"; shift 2;;
    --clients-param) CLIENTS_PARAM="$2"; shift 2;;
    --user) ENGINE_USER="$2"; shift 2;;
    --pass) ENGINE_PASS="$2"; shift 2;;
    --tag) TAGS+=("$2"); shift 2;;
    --track-params) EXTRA_PARAMS="$2"; shift 2;;
    --dist-version) DIST_VERSION="$2"; shift 2;;
    --test-mode) TEST_MODE="--test-mode"; shift 1;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TF_DIR="$ROOT/terraform"

RALLY_IP=$(cd "$TF_DIR" && terraform output -raw rally_public_ip)
[ -n "$RALLY_IP" ] || { echo "取不到 rally_public_ip，先 make up" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${TRACK}-${CHALLENGE}-${STAMP}"
USER_TAGS=""
# esrally 的 --user-tags 必须是 key:value（冒号），多个之间逗号分隔。
# 命令行习惯写 --tag arch=x86（等号），这里统一转成冒号；否则 esrally 解析会报
# "not enough values to unpack (expected 2, got 1)" 并直接拒绝开跑。
for t in "${TAGS[@]}"; do USER_TAGS="${USER_TAGS}${t//=/:},"; done
USER_TAGS="${USER_TAGS}run:${RUN_ID}"

CLIENT_OPTS=""
[ -n "$CLIENTS" ] && CLIENT_OPTS="--track-params=${CLIENTS_PARAM}:${CLIENTS}${EXTRA_PARAMS:+,$EXTRA_PARAMS}"
[ -n "$EXTRA_PARAMS" ] && [ -z "$CLIENTS" ] && CLIENT_OPTS="--track-params=${EXTRA_PARAMS}"

echo "=== 触发压测 ==="
echo "  rally   : $RALLY_IP"
echo "  track   : $TRACK ($CHALLENGE)"
echo "  clients : ${CLIENTS:-默认}  (参数名 ${CLIENTS_PARAM})"
echo "  run id  : $RUN_ID"

# 远端执行脚本
read -r -d '' REMOTE <<'EOS' || true
set -euo pipefail
source /etc/es-oss.conf
TARGETS=$(cat /etc/es-targets.conf)
# 密码由 userdata-rally 从 terraform 注入到 /etc/es-oss.conf（chmod 600）。
# 不在 Mac 侧硬编码：ES 与 easysearch 的密码不同（easysearch 策略要求 >=9 位），
# 统一由 tfvars 的 es_password 决定，避免两边不一致。
ADMIN_PASS="${ADMIN_PASS:-__PASS__}"
RALLY_BIN=${RALLY_BIN:-/opt/esrally/bin/esrally}
RUN_ID="__RUN_ID__"
OUT="/data/rally/results/${RUN_ID}"
mkdir -p "$OUT"

echo "target-hosts: $TARGETS"

# 优先用离线语料（镜像烘焙）。国内 github/GCS 都拉不到，
# 走联网路径基本必失败，所以找不到本地 track 时给出明确警告而不是静默回退。
TRACK_LOCAL="/data/rally/benchmarks/tracks/__TRACK__"
TRACK_ARG="__TRACK_PATH__"
if [ -n "$TRACK_ARG" ]; then
  [ -d "$TRACK_ARG" ] || { echo "ERROR: 指定的 --track-path 不存在：$TRACK_ARG" >&2; exit 1; }
elif [ -d "$TRACK_LOCAL" ]; then
  TRACK_ARG="--track-path=$TRACK_LOCAL"
else
  echo "WARN: 本地无 track（$TRACK_LOCAL），改用 --track=__TRACK__ 联网下载 —— 国内大概率失败"
  TRACK_ARG="--track=__TRACK__"
fi
echo "track     : $TRACK_ARG"

# 语料预检：文件缺失时 esrally 会去 GCS 下载并卡很久，提前报出来
DATA_DIR="/data/rally/benchmarks/data/__TRACK__"
if [ -d "$DATA_DIR" ]; then
  echo "corpus    : $(ls "$DATA_DIR" | tr '\n' ' ')"
else
  echo "WARN: 本地无语料目录 $DATA_DIR，esrally 将尝试联网下载"
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
} | tee "$OUT/env-fingerprint.txt"

# 起跑
"$RALLY_BIN" race \
  --pipeline=benchmark-only \
  --target-hosts="$TARGETS" \
  "$TRACK_ARG" \
  --challenge="__CHALLENGE__" \
  --client-options="basic_auth_user:'__USER__',basic_auth_password:'$ADMIN_PASS',verify_certs:false" \
  __CLIENT_OPTS__ \
  __DIST_VERSION__ \
  __TEST_MODE__ \
  --user-tags="__USER_TAGS__" \
  --report-format=markdown \
  --report-file="$OUT/report.md" 2>&1 | tee "$OUT/rally.log"

# 归档到 OSS
cd /data/rally/results
tar czf "/tmp/${RUN_ID}.tar.gz" "$RUN_ID"
if command -v ossutil64 >/dev/null 2>&1; then
  ossutil64 cp "/tmp/${RUN_ID}.tar.gz" "oss://${OSS_BUCKET}/${OSS_PREFIX}/${RUN_ID}.tar.gz" -f
  echo "archived -> oss://${OSS_BUCKET}/${OSS_PREFIX}/${RUN_ID}.tar.gz"
else
  echo "WARN: ossutil64 未安装，产物仅留在实例上 /tmp/${RUN_ID}.tar.gz"
fi
EOS

REMOTE=${REMOTE//__RUN_ID__/$RUN_ID}
# 先替换 __TRACK_PATH__ 再替换 __TRACK__，避免前缀互相干扰
REMOTE=${REMOTE//__TRACK_PATH__/$TRACK_PATH}
REMOTE=${REMOTE//__TRACK__/$TRACK}
REMOTE=${REMOTE//__CHALLENGE__/$CHALLENGE}
REMOTE=${REMOTE//__USER__/$ENGINE_USER}
REMOTE=${REMOTE//__PASS__/$ENGINE_PASS}
REMOTE=${REMOTE//__CLIENT_OPTS__/$CLIENT_OPTS}
REMOTE=${REMOTE//__TEST_MODE__/$TEST_MODE}
# easysearch 自报版本 2.4.0，esrally 要求集群版本 >= 6.8.0；
# 用 --distribution-version 告知真实血统（easysearch 2.x 基于 ES 7.10.2）
if [ -n "$DIST_VERSION" ]; then
  REMOTE=${REMOTE//__DIST_VERSION__/--distribution-version=$DIST_VERSION}
else
  REMOTE=${REMOTE//__DIST_VERSION__/}
fi
REMOTE=${REMOTE//__USER_TAGS__/$USER_TAGS}

ssh -o StrictHostKeyChecking=no root@"$RALLY_IP" "cat > /tmp/run-bench-remote.sh" <<< "$REMOTE"
ssh -o StrictHostKeyChecking=no root@"$RALLY_IP" "bash /tmp/run-bench-remote.sh"

echo
echo "完成。取回产物：  make fetch RUN_ID=$RUN_ID"
