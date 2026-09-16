#!/bin/bash
# 新机器一键引导：clone 之后把「能部署」前的本地准备做完。
#
#   make setup          # 全套：生成 tfvars（自动填公钥/出口 IP）+ 预热 provider + 自检
#
# 也可单独执行：
#   scripts/bootstrap.sh vars        # 生成 terraform/terraform.tfvars
#   scripts/bootstrap.sh providers   # 预热 alicloud provider 到本地镜像（可离线 init）
#   scripts/bootstrap.sh check       # 自检清单（含凭据是否已配置）
#
# 凭据约定：阿里云 AccessKey 由用户手动 `aliyun configure` 输入（AK 来自 RAM 控制台
# 创建用户时下载的结果文件），只写入 ~/.aliyun/config.json —— 用户主目录、仓库之外。
# 本脚本只读取验证是否已配置，不复制、不打印密钥本身。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TF_DIR="$ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
MIRROR_DIR="${HOME}/.terraform.d/plugins-mirror"

ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }

tf_bin() {
  if [ -x "$ROOT/bin/terraform" ]; then echo "$ROOT/bin/terraform"
  elif command -v terraform >/dev/null 2>&1; then echo terraform
  else echo ""; fi
}

mirror_has_alicloud() {
  find "$MIRROR_DIR/registry.terraform.io/aliyun" -name 'terraform-provider-alicloud*' 2>/dev/null | head -n1
}

# ---------- vars：生成 terraform.tfvars 并自动填充 ----------
# 把 file 里 key=value 行的值替换为 v（v 需含引号）。key 不存在时返回 9。
replace_kv() {
  local f=$1 k=$2 v=$3 tmp
  tmp=$(mktemp)
  if awk -v pat="^[[:space:]]*${k}[[:space:]]*=" -v v="$v" '
      BEGIN { hit = 0 }
      $0 ~ pat { gsub(/&/, "&&", v); sub(/=.*/, "= " v); hit = 1 }
      { print }
      END { exit (hit ? 0 : 9) }' "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; return 1
  fi
}

# 直连探测本机出口 IP。必须 --noproxy：若走代理，拿到的是代理出口 IP，
# 写进安全组会导致 SSH 放行了错误地址。
detect_egress_ip() {
  local ip url
  for url in https://ip.3322.net https://ifconfig.me/ip https://api.ipify.org; do
    ip=$(curl -4 -s --noproxy '*' -m 5 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    case "$ip" in *[0-9].[0-9]*.[0-9]*.[0-9]*) echo "$ip"; return 0 ;; esac
  done
  return 1
}

cmd_vars() {
  if [ -f "$TFVARS" ]; then
    echo "  ✅ terraform/terraform.tfvars 已存在，跳过生成（要重做先删掉它）"
  else
    [ -f "$TF_DIR/terraform.tfvars.example" ] || { echo "ERROR: 缺少 terraform.tfvars.example" >&2; exit 1; }
    cp "$TF_DIR/terraform.tfvars.example" "$TFVARS"
    echo "  ✅ 已从 example 生成 terraform/terraform.tfvars"
  fi

  # SSH 公钥：优先 SSH_PUBKEY 环境变量，其次 ~/.ssh 下常见命名的公钥
  local pk="${SSH_PUBKEY:-}"
  if [ -z "$pk" ]; then
    local f
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
      if [ -f "$f" ]; then pk=$(cat "$f"); break; fi
    done
  fi
  if [ -n "$pk" ]; then
    if replace_kv "$TFVARS" public_key "\"$pk\""; then
      echo "  ✅ public_key 已自动填入（$(echo "$pk" | awk '{print $1}') …）"
    else
      warn "tfvars 里没有 public_key 行，未填"
    fi
  else
    warn "未找到 SSH 公钥：先 ssh-keygen -t ed25519 再重跑 make setup"
  fi

  local ip; ip=$(detect_egress_ip || true)
  if [ -n "$ip" ]; then
    if replace_kv "$TFVARS" operator_cidr "\"$ip/32\""; then
      echo "  ✅ operator_cidr 已填为本机出口 IP：$ip/32（换网络后 IP 变了就改这里并重新 apply）"
    else
      warn "tfvars 里没有 operator_cidr 行，未填"
    fi
  else
    warn "探测出口 IP 失败，请手工填 operator_cidr（curl -4 ifconfig.me 查看后填入）"
  fi

  echo "  ✍️  需手工确认：oss_bucket（产物归档桶）等；镜像 ID 在 make image-* 构建后回填"
}

# ---------- providers：预热 alicloud provider 到本地镜像 ----------
# 预热后 terraform init 完全离线；失败不致命 —— init 会回退 registry 直连。
cmd_providers() {
  local tf; tf=$(tf_bin)
  if [ -z "$tf" ]; then
    warn "未找到 terraform（bin/ 或 PATH），跳过 provider 预热"
    return 0
  fi
  if [ -n "$(mirror_has_alicloud)" ]; then
    echo "  ✅ provider 本地镜像已就绪：$MIRROR_DIR"
    return 0
  fi
  echo "  … 预热 alicloud provider 到本地镜像（首次约 80MB；失败不影响使用）"
  mkdir -p "$MIRROR_DIR"
  if (cd "$TF_DIR" && env -u TF_CLI_CONFIG_FILE "$tf" providers mirror "$MIRROR_DIR" >/dev/null 2>&1); then
    echo "  ✅ provider 已缓存到 $MIRROR_DIR"
  else
    warn "provider 预热失败（网络原因？）。不影响使用：terraform init 会走 registry 直连"
  fi
}

# ---------- check：自检清单 ----------
cmd_check() {
  local fails=0
  echo "自检清单："

  local tf; tf=$(tf_bin)
  if [ -n "$tf" ]; then ok "terraform：$tf"; else
    bad "terraform 未安装（brew install terraform，或把官方二进制放 bin/terraform）"; fails=$((fails+1))
  fi

  if command -v jq >/dev/null 2>&1; then ok "jq"; else
    bad "jq 未安装（brew install jq）"; fails=$((fails+1))
  fi

  if command -v aliyun >/dev/null 2>&1; then
    ok "aliyun CLI"
    local conf="${ALIYUN_CONF:-$HOME/.aliyun/config.json}"
    if [ -f "$conf" ] && command -v jq >/dev/null 2>&1; then
      local cur ak
      cur=$(jq -r '.current // "default"' "$conf" 2>/dev/null)
      ak=$(jq -r --arg n "$cur" '.profiles[]? | select(.name==$n) | .access_key_id // empty' "$conf" 2>/dev/null)
      if [ -n "$ak" ]; then
        ok "阿里云凭据：${ak:0:6}****（profile=${cur}）"
      else
        bad "凭据未配置：执行 aliyun configure，输入 RAM 用户的 AccessKeyId / AccessKeySecret"; fails=$((fails+1))
      fi
    else
      bad "找不到 ${conf}：执行 aliyun configure 完成凭据配置"; fails=$((fails+1))
    fi
  else
    bad "aliyun CLI 未安装（brew install aliyun-cli）"; fails=$((fails+1))
  fi

  if [ -n "${SSH_PUBKEY:-}" ] || [ -f ~/.ssh/id_ed25519.pub ] || [ -f ~/.ssh/id_rsa.pub ]; then
    ok "SSH 公钥"
  else
    bad "未找到 SSH 公钥（ssh-keygen -t ed25519 生成一把）"; fails=$((fails+1))
  fi

  if [ -f "$TFVARS" ]; then
    ok "terraform/terraform.tfvars"
    if grep -q 'my-esbench-results' "$TFVARS"; then
      warn "oss_bucket 还是占位符，记得改成你自己的 bucket 名"
    fi
  else
    bad "terraform/terraform.tfvars 不存在（make setup 自动生成）"; fails=$((fails+1))
  fi

  # 以下为可选项，缺失只提醒不拦路
  if command -v ossutil64 >/dev/null 2>&1; then ok "ossutil64"
  else warn "ossutil64 未安装（只有 make fetch 需要；若装的是 ossutil，可软链为 ossutil64）"
  fi
  if command -v docker >/dev/null 2>&1; then ok "docker（local-validate 用）"
  else warn "docker 不可用（只有 make local-validate 需要，可跳过）"
  fi
  if [ -f "$ROOT/corpus/geonames-corpus.tar.gz" ]; then ok "语料离线包已生成"
  else warn "语料包未生成：make corpus（构建 rally 镜像前必须做）"
  fi
  if [ -n "$(mirror_has_alicloud)" ]; then ok "terraform provider 本地镜像"
  else warn "provider 未预热（make setup 会尝试；未预热也能 init，走 registry 直连）"
  fi

  echo ""
  if [ "$fails" -gt 0 ]; then
    echo "还有 $fails 项必过项未就绪，按上面 ❌ 的提示处理后重跑 make setup。"
    exit 1
  fi
  echo "必过项全部就绪 ✅  下一步：make corpus → make image-es / image-rally → make up（详见 README 第 1.4 节）"
}

# ---------- 入口 ----------
SUB="${1:-all}"; [ $# -gt 0 ] && shift
case "$SUB" in
  vars)      cmd_vars ;;
  providers) cmd_providers ;;
  check)     cmd_check ;;
  all)       cmd_vars; cmd_providers; cmd_check ;;
  *) echo "用法: bootstrap.sh [all|vars|providers|check]" >&2; exit 1 ;;
esac
