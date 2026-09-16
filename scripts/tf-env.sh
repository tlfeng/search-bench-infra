#!/bin/bash
# 从 ~/.aliyun/config.json 读取 AccessKey，导出成 terraform(alicloud provider) 需要的环境变量。
#
# 为什么要这个：用户只需执行一次 `aliyun configure`，之后 terraform 自动取用；
# 密钥只存在于当前 shell 的内存里 —— 不写进 terraform.tfvars、不落盘、不经过对话。
#
# 用法（注意前面那个点，是 source 不是执行）：
#     . scripts/tf-env.sh
#
# 若已经设了 ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY 环境变量，则原样沿用不覆盖。

ALIYUN_CONF="${ALIYUN_CONF:-$HOME/.aliyun/config.json}"
# bash 用 BASH_SOURCE；zsh 没有 BASH_SOURCE，sourcing 时 $0 即被 source 的文件路径
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ---- Terraform CLI 配置：本地有 alicloud provider 镜像时，用 filesystem_mirror 离线安装 ----
# 镜像目录随用户主目录走（~/.terraform.d/plugins-mirror，`make setup` 预热），
# 所以这里在运行时按当前 $HOME 生成配置——不能把路径写死在仓库文件里，否则换机器必挂。
# 没有本地镜像时不设置 TF_CLI_CONFIG_FILE，terraform init 走 registry 直连（能用，只是慢）。
if [ -z "${TF_CLI_CONFIG_FILE:-}" ]; then
  MIRROR_DIR="${HOME}/.terraform.d/plugins-mirror"
  if [ -n "$(find "$MIRROR_DIR/registry.terraform.io/aliyun" -name 'terraform-provider-alicloud*' 2>/dev/null | head -n1)" ]; then
    GEN="$HERE/.tf-cli.generated.hcl"
    # 先写临时文件再 mv 原子替换：并发 source（多 stack 同时 init）时，
    # 直接 cat > 目标文件会让另一个进程读到「写了一半」的 HCL。
    GEN_TMP="$GEN.$$"
    cat > "$GEN_TMP" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$MIRROR_DIR"
    include = ["registry.terraform.io/aliyun/alicloud"]
  }
  direct {
    exclude = ["registry.terraform.io/aliyun/alicloud"]
  }
}
EOF
    mv -f "$GEN_TMP" "$GEN"
    export TF_CLI_CONFIG_FILE="$GEN"
  fi
fi

_already() {
  [ -n "${ALICLOUD_ACCESS_KEY:-}" ] && [ -n "${ALICLOUD_SECRET_KEY:-}" ]
}

if _already; then
  # 提示语一律走 stderr：调用方常写 $(scripts/tf.sh output -raw ...)，
  # 混到 stdout 会把返回值污染掉。
  echo "  [tf-env] 已存在 ALICLOUD_* 环境变量，直接沿用" >&2
  return 0 2>/dev/null || exit 0
fi

if [ ! -f "$ALIYUN_CONF" ]; then
  echo "ERROR: 找不到 $ALIYUN_CONF" >&2
  echo "       请先执行：aliyun configure" >&2
  return 1 2>/dev/null || exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 需要 jq 来解析 $ALIYUN_CONF" >&2
  return 1 2>/dev/null || exit 1
fi

CUR=$(jq -r '.current // "default"' "$ALIYUN_CONF" 2>/dev/null)
AK=$(jq -r --arg n "$CUR" '.profiles[]? | select(.name==$n) | .access_key_id // empty' "$ALIYUN_CONF" 2>/dev/null)
SK=$(jq -r --arg n "$CUR" '.profiles[]? | select(.name==$n) | .access_key_secret // empty' "$ALIYUN_CONF" 2>/dev/null)
RG=$(jq -r --arg n "$CUR" '.profiles[]? | select(.name==$n) | .region_id // empty' "$ALIYUN_CONF" 2>/dev/null)

if [ -z "$AK" ] || [ -z "$SK" ]; then
  echo "ERROR: 从 $ALIYUN_CONF 读不到 AK/SK（当前 profile: ${CUR}）" >&2
  echo "       请重新执行：aliyun configure" >&2
  return 1 2>/dev/null || exit 1
fi

export ALICLOUD_ACCESS_KEY="$AK"
export ALICLOUD_SECRET_KEY="$SK"
export ALICLOUD_REGION="${ALICLOUD_REGION:-${RG:-cn-hangzhou}}"

# 只回显 AK 前 6 位，便于确认取到的是哪把钥匙，不泄露密钥本身。
# 必须走 stderr：本文件被 tf.sh source，而调用方经常用 $(tf.sh output -raw ...) 捕获 stdout。
# stack 用 ${VAR:+...} 可选拼上：直接 source 本文件的地方（如 bench-matrix 的预检）没有 STACK，
# 写死就会显示成 "stack=?"，比不显示更让人困惑。
echo "  [tf-env] 凭据已加载：${AK:0:6}****  region=${ALICLOUD_REGION:-${RG:-cn-hangzhou}}${STACK:+（stack=${STACK}）}" >&2
