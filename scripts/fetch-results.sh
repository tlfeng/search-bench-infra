#!/bin/bash
# 取回压测产物。两条路：从 OSS 拉（实例已销毁也能取），或从实例 scp（实例还在）。
#
# 用法：
#   ./fetch-results.sh                     # 拉全部
#   ./fetch-results.sh --run-id <RUN_ID>   # 只拉一场
#   ./fetch-results.sh --from instance     # 实例还在时直接 scp
set -euo pipefail

RUN_ID=""
FROM="oss"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2;;
    --from) FROM="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TF_DIR="$ROOT/terraform"

# 这里刻意不再手动 source tf-env.sh：terraform 调用统一走 scripts/tf.sh（凭据 + workspace 一并处理）。
# 顺带修掉一个老 bug —— tf-env.sh 的「凭据已加载」原先打在 stdout 上，会被
# RALLY_IP=$(...) 一起捕获，于是 scp 的地址里混进一句中文提示，连不上还看不出原因。
LOCAL_DIR="${LOCAL_DIR:-$ROOT/results}"
mkdir -p "$LOCAL_DIR"

# 调试档不用 OSS（oss_bucket=unused-in-debug），本机也未必装 ossutil64。
# 这时硬走 OSS 只会 exit 1、产物取不回来；自动回退成 scp 更实用。
if [ "$FROM" = "oss" ] && ! command -v ossutil64 >/dev/null 2>&1; then
  echo "WARN: 本机没有 ossutil64，自动改用 --from instance（scp）"
  FROM="instance"
fi

if [ "$FROM" = "oss" ]; then
  # bucket / prefix 一律优先从 terraform output 取，而不是 grep tfvars：
  # 多栈并存时 oss_prefix 会被 Makefile 按 STACK 覆盖成 esrally-results/<stack>，
  # 而 tfvars 里只有基前缀，照着它去拉会拉到别的 stack 的产物（或什么都拉不到）。
  BUCKET=$("$HERE/tf.sh" output -raw oss_bucket 2>/dev/null || \
           grep -E '^oss_bucket' "$TF_DIR/terraform.tfvars" | sed -E 's/.*"(.*)"/\1/')
  PREFIX=$("$HERE/tf.sh" output -raw oss_prefix 2>/dev/null || \
           grep -E '^oss_prefix' "$TF_DIR/terraform.tfvars" | sed -E 's/.*"(.*)"/\1/')
  command -v ossutil64 >/dev/null 2>&1 || { echo "需要 ossutil64" >&2; exit 1; }

  echo "从 OSS 拉取 oss://${BUCKET}/${PREFIX} -> $LOCAL_DIR"
  if [ -n "$RUN_ID" ]; then
    ossutil64 cp -r "oss://${BUCKET}/${PREFIX}/${RUN_ID}.tar.gz" "$LOCAL_DIR/" -f
  else
    ossutil64 cp -r "oss://${BUCKET}/${PREFIX}/" "$LOCAL_DIR/" -f
  fi
else
  RALLY_IP=$("$HERE/tf.sh" output -raw rally_public_ip)
  echo "从实例 scp root@${RALLY_IP}:/data/rally/results -> $LOCAL_DIR"
  if [ -n "$RUN_ID" ]; then
    scp -r -o StrictHostKeyChecking=no "root@${RALLY_IP}:/data/rally/results/${RUN_ID}" "$LOCAL_DIR/"
  else
    scp -r -o StrictHostKeyChecking=no "root@${RALLY_IP}:/data/rally/results/"* "$LOCAL_DIR/"
  fi
fi

echo
echo "产物已落到：$LOCAL_DIR"
find "$LOCAL_DIR" -name '*.tar.gz' -o -name 'report.md' | head -20
