#!/bin/bash
# 查询阿里云账户余额与当月消耗。
#
# 用途：
#   1. 确认按量付费的「余额门槛」是否满足（余额不足时 CreateInstance 会报
#      InvalidAccountStatus.NotEnoughBalance，403）；
#   2. 核实际花费，验证串行开机/竞价等省钱策略的效果。
#
# 前置：RAM 用户需具备 **BSS 只读** 权限（系统策略 AliyunBSSReadOnlyAccess）。
#       纯只读即可 —— 本脚本不涉及任何资金操作。
#
# 用法：
#   ./scripts/bss-report.sh            # 余额 + 当月消耗
#   ./scripts/bss-report.sh --month 2026-08
set -euo pipefail

MONTH="$(date +%Y-%m)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --month) MONTH="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 复用凭据注入（只读查询，不会产生费用）
[ -f "$HERE/tf-env.sh" ] && . "$HERE/tf-env.sh" >/dev/null || true

# aliyun CLI 不一定在沙箱 PATH 里（macOS 常见装在 /opt/homebrew/bin）
if ! command -v aliyun >/dev/null 2>&1; then
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    if [ -x "$d/aliyun" ]; then PATH="$d:$PATH"; export PATH; break; fi
  done
fi
if ! command -v aliyun >/dev/null 2>&1; then
  echo "ERROR: 找不到 aliyun CLI。macOS 上执行：brew install aliyun-cli" >&2
  exit 1
fi

# 缺权限时给出可执行的指引，而不是甩一串 SDK 错误
need_bss() {
  echo
  echo "需要 BSS 只读权限才能查询。请在 RAM 控制台给当前用户加上系统策略"
  echo "  AliyunBSSReadOnlyAccess"
  echo "然后重试。   快捷入口：https://ram.console.aliyun.com/users"
}

echo "=== 账户余额 ==="
BAL=$(aliyun bssopenapi QueryAccountBalance 2>&1) || true
if echo "$BAL" | grep -qiE 'not ?authorized|nopermission|forbidden|not authorized to (call|do)'; then
  need_bss
  exit 2
fi
echo "$BAL" | jq -r '
  .Data as $d |
  if $d == null then "  " + (..|strings) else
  "  可用额度:     \($d.AvailableAmount // "-") \($d.Currency // "CNY")\n" +
  "  其中现金:     \($d.AvailableCashAmount // "-")\n" +
  "  信用额度:     \($d.CreditAmount // "-")\n" +
  "  网商信用额度: \($d.MybankCreditAmount // "-")"
  end' 2>/dev/null || echo "$BAL" | head -12

echo
echo "=== 当月消耗（${MONTH}）==="
BILL=$(aliyun bssopenapi QueryAccountBill --BillingCycle "$MONTH" 2>&1) || true
if echo "$BILL" | grep -qiE 'not ?authorized|nopermission|forbidden|not authorized to (call|do)'; then
  echo "  （账单查询也需要 BSS 只读权限）"
else
  echo "$BILL" | jq -r '
    .Data.Items.Item[]? |
    "  \(.ProductName // .ProductCode): 应付 \(.PretaxAmount // "-")  已付 \(.PaymentAmount // "-")"' 2>/dev/null \
    || echo "$BILL" | head -12
  TOTAL=$(echo "$BILL" | jq -r '[.Data.Items.Item[]?.PretaxAmount | tonumber?] | add // empty' 2>/dev/null || true)
  [ -n "$TOTAL" ] && echo "  ---- 合计: $TOTAL"
fi

echo
echo "提示：按量付费创建实例要求账户余额达到门槛（通常 100 元）。"
echo "      本套环境调试期实际消耗通常只有几元，余额够用很久。"
