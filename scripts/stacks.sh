#!/bin/bash
# 列出所有 bench 环境：本地（workspace / 产物目录 / provider 缓存）+ 云端（仍在计费的实例）。
#
# 为什么需要这条命令：并发多套环境时，最容易忘的是「云端还有一套在烧钱」。
# 本地信息 terraform 自己就能查到，云端信息只能问云 API —— 这里把两边按 stack 对齐展示。
#
# 用法：
#   scripts/stacks.sh                 # 本地 + 云端
#   scripts/stacks.sh --local-only    # 不调云 API（0 费用、无凭据也能跑）
#
# 环境变量：
#   REGION        云地域（默认取 terraform.tfvars 的 region）
#   BENCH_PREFIX  资源名前缀（默认 esbench-perf，即 variables.tf 里 project-env 的默认值）
#
# 实例名与 stack 的对应关系（由 terraform/main.tf 的 name_prefix 决定）：
#   <prefix>-<role>[-N]           -> stack = default
#   <prefix>-<stack>-<role>[-N]   -> stack = <stack>
# 因此 stack 名不能取 es / rally（会与角色名歧义），terraform 的 validation 已拦住。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TFV="$ROOT/terraform/terraform.tfvars"

LOCAL_ONLY=0
if [ "${1:-}" = "--local-only" ]; then LOCAL_ONLY=1; fi

tfvars_get() { # $1 = 键名
  [ -f "$TFV" ] || return 0
  # BSD grep 不认 \s，用 POSIX 字符类
  sed -nE 's/^[[:space:]]*'"$1"'[[:space:]]*=[[:space:]]*"(.*)".*/\1/p' "$TFV" | head -1
}

REGION="${REGION:-$(tfvars_get region)}"
REGION="${REGION:-cn-hangzhou}"
BENCH_PREFIX="${BENCH_PREFIX:-esbench-perf}"

echo "=== 本地 ==="
if [ -d "$ROOT/.stacks" ] || [ -d "$ROOT/terraform/.terraform" ]; then
  echo "terraform workspaces（一个 workspace = 一套独立 state）："
  # 直接读 state 目录，避免依赖 terraform 与 workspace 指针
  if [ -d "$ROOT/terraform/terraform.tfstate.d" ]; then
    ls -1 "$ROOT/terraform/terraform.tfstate.d" 2>/dev/null | sed 's/^/  /' || true
  fi
  echo "  default（state 在 terraform/terraform.tfstate）"
else
  echo "  (未初始化)"
fi

echo
echo "provider 缓存（按 stack 隔离，互不干扰）："
ls -1 "$ROOT/.stacks" 2>/dev/null | sed 's/^/  .stacks\//' || true

echo
echo "本地产物（results/ 下；default stack 用历史路径，不套子目录）："
if [ -d "$ROOT/results" ]; then
  for d in "$ROOT"/results/*/; do
    [ -d "$d" ] || continue
    echo "  results/$(basename "$d")/"
  done
fi

if [ "$LOCAL_ONLY" = 1 ]; then
  exit 0
fi

echo
echo "=== 云端（region=${REGION}，实例名前缀 ${BENCH_PREFIX}）==="

# aliyun CLI 未必在 PATH 里（沙箱默认 PATH 没有 /opt/homebrew/bin）
ALIYUN="$(command -v aliyun || true)"
if [ -z "$ALIYUN" ]; then
  for c in /opt/homebrew/bin/aliyun "$HOME/.local/bin/aliyun"; do
    if [ -x "$c" ]; then ALIYUN="$c"; break; fi
  done
fi
if [ -z "$ALIYUN" ]; then
  echo "  (跳过：找不到 aliyun CLI。要查云端请安装 aliyun CLI，或加 --local-only 明确只看本地)" >&2
  exit 0
fi

# 凭据：只读查询，只存在于当前进程。
# 用 if 包住而不是直接 `.` —— 少了凭据只该降级成"只看本地"，不该让整条命令失败：
# 这条命令的用途恰恰是"确认云端还剩什么"，凭据过期时更需要它把本地信息说出来。
if ! . "$HERE/tf-env.sh"; then
  echo "  (跳过：无法加载阿里云凭据，先执行 aliyun configure)" >&2
  exit 0
fi

# InstanceName 支持通配符（实测 TotalCount 正确），比拉全量再本地过滤更省调用
RAW="$("$ALIYUN" ecs DescribeInstances --RegionId "$REGION" --PageSize 100 \
        --InstanceName "${BENCH_PREFIX}*" 2>&1)" || {
  echo "  ⚠️  云 API 调用失败，只显示本地信息：" >&2
  echo "$RAW" | tail -3 | sed 's/^/    /' >&2
  exit 0
}

if ! echo "$RAW" | jq -e '.Instances' >/dev/null 2>&1; then
  echo "  ⚠️  云 API 返回的不是预期 JSON，只显示本地信息" >&2
  exit 0
fi

# --PageSize 100 不做分页：真到 100 台以上，说明用法已超出脚本假设。
# 必须明说"被截断"，不能默默少列 —— 这条命令的用途是防漏计费，漏列正是它最危险的失效方式。
TOTAL="$(echo "$RAW" | jq -r '.TotalCount // 0' 2>/dev/null || echo 0)"
if [ "${TOTAL:-0}" -gt 100 ] 2>/dev/null; then
  echo "  ⚠️  匹配到 $TOTAL 台，超过单页 100 台上限，下面只列出前 100 台 —— 请改用控制台核对" >&2
fi

# 按 stack 分组输出。用 awk 分组而不是 bash 关联数组 —— macOS 自带 bash 3.2 没有 declare -A。
# 只保留 spot/on-demand 列：InstanceChargeType 对竞价也是 PostPaid，单看不出来计费方式。
echo "$RAW" | jq -r '
  .Instances.Instance[]? |
  [ .InstanceName, .Status, .InstanceType, .ZoneId,
    (if .SpotStrategy == "SpotAsPriceGo" or .SpotStrategy == "SpotWithPriceLimit" then "spot" else "on-demand" end),
    (.CreationTime // "-")
  ] | @tsv
' | awk -F'\t' -v prefix="$BENCH_PREFIX-" '
  {
    name = $1
    rest = substr(name, length(prefix) + 1)
    if (rest ~ /^(es|rally)(-|$)/) stack = "default"
    else { split(rest, a, "-"); stack = a[1] }
    if (!(stack in seen)) { seen[stack] = 1; order[++n] = stack }
    rows[stack] = rows[stack] sprintf("    %-34s %-9s %-16s %-14s %-10s %s\n", $1, $2, $3, $4, $5, $6)
    total[stack]++; if ($5 == "spot") spot[stack]++
  }
  END {
    if (n == 0) { print "  (没有以 " prefix "* 开头的实例 —— 云端没有在计费的环境)"; exit }
    grand = 0
    for (i = 1; i <= n; i++) {
      s = order[i]
      printf "  stack %s（%d 台，spot %d 台）\n", s, total[s], spot[s] + 0
      printf "%s", rows[s]
      grand += total[s]
    }
    printf "  合计 %d 台在计费\n", grand
  }
'
