#!/bin/bash
# 直连探测本机出口 IPv4：成功打印裸 IP（不带掩码），失败返回非 0。
# 被两处共用：
#   - Makefile 在 up/plan 时解析 operator_cidr（tfvars 留空时自动放行当前出口）
#   - bootstrap.sh 生成 tfvars 后给出提示
# 必须直连（--noproxy）：走代理拿到的是代理出口 IP，写进安全组就放行了错误地址。
set -u

for url in https://ip.3322.net https://ifconfig.me/ip https://api.ipify.org; do
  ip=$(curl -4 -s --noproxy '*' -m 5 "$url" 2>/dev/null | tr -d '[:space:]') || continue
  case "$ip" in
    *[0-9].[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$ip"; exit 0 ;;
  esac
done
exit 1
