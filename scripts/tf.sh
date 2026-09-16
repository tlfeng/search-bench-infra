#!/bin/bash
# terraform 的唯一调用入口：保证每次都在 STACK 对应的 workspace 与 provider 缓存里执行。
#
# 为什么要把 terraform 收成一个入口（而不是每个 Makefile target 各写一遍）：
#   terraform workspace 的「当前是哪个」存在 $TF_DATA_DIR/environment 里，是一份
#   **有状态**的指针。只要有一个调用点忘了 select，apply 就会打到别的 stack 上。
#   官方文档把这一点列为 workspace 的主要风险。收成一个入口，就只剩一处可能出错。
#
# 用法：
#   STACK=a scripts/tf.sh plan -var=...
#   STACK=a scripts/tf.sh output -raw rally_public_ip
#
# 环境变量：
#   STACK    环境切片键（默认 default；default 时资源名不带后缀）
#   TF_DIR   terraform 配置目录（默认 <repo>/terraform）
#   TF_BIN   terraform 可执行文件（默认优先 <repo>/bin/terraform）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

TF_DIR="${TF_DIR:-$ROOT/terraform}"
STACK="${STACK:-default}"
export STACK

if [ -n "${TF_BIN:-}" ]; then
  TERRAFORM="$TF_BIN"
elif [ -x "$ROOT/bin/terraform" ]; then
  # 项目内二进制优先：不依赖 PATH，也不污染系统（沙箱默认 PATH 里没有 terraform）
  TERRAFORM="$ROOT/bin/terraform"
else
  TERRAFORM="$(command -v terraform || true)"
fi
if [ -z "$TERRAFORM" ] || [ ! -x "$TERRAFORM" ]; then
  echo "ERROR: 找不到 terraform。可设 TF_BIN=/path/to/terraform，或把官方二进制放到 $ROOT/bin/terraform" >&2
  exit 1
fi

# provider 缓存与「当前 workspace 指针」都按 stack 隔离。
# 不隔离时，两个终端并发 init/apply 会互相改写 .terraform/environment，
# 结果是「A 切成 stack a 之后，B 的 apply 落到了 a 上」——这类事故排查成本极高。
#
# 这里**无条件**覆盖而不写成 ${TF_DATA_DIR:-...}：继承来的旧值会让"按 stack 隔离"
# 变成一句空话（环境里留着一个 stale TF_DATA_DIR 就静默失效），而这正是本脚本存在的理由。
# 需要指向别处时应该换 STACK，而不是改这个路径。
export TF_DATA_DIR="$ROOT/.stacks/$STACK/.terraform"
mkdir -p "$TF_DATA_DIR"

# 只读子命令不需要云凭据。区分开是为了让 make status / ssh-* 在凭据过期时仍能用
# （历史上 ssh-rally 就是刻意不注入凭据的，因为 terraform output 只读本地 state）。
NEEDS_CREDS=1
case "${1:-}" in
  output|validate|fmt|show|workspace|version|providers|state) NEEDS_CREDS=0 ;;
esac

# 凭据注入：只存在于当前进程内存，不落盘（不写 tfvars、不经过对话）。
# 注意 tf-env.sh 的信息回显必须走 stderr，否则会污染 $(...) 捕获
# —— fetch-results.sh 的 RALLY_IP=$(tf.sh output -raw ...) 就会被注入一行提示语。
if ! . "$HERE/tf-env.sh"; then
  if [ "$NEEDS_CREDS" = 1 ]; then
    echo "ERROR: 无法加载阿里云凭据。先执行 aliyun configure" >&2
    exit 1
  fi
  # ${1:-} 而不是 $1：脚本可能被无参数调用（等价于 terraform 无子命令，打印帮助），
  # 此时 set -u 下直接引用 $1 会抛 unbound variable，把一个可读的错误变成一堆栈回溯。
  echo "  [tf.sh] 未加载到凭据；${1:-<无子命令>} 不需要凭据，继续" >&2
fi

cd "$TF_DIR"

# 首次使用某个 stack（或全新机器）先把 provider 装好；有本地镜像时不走网络
if [ ! -d "$TF_DATA_DIR/providers" ]; then
  echo "  [tf.sh] stack=$STACK 首次使用，先 terraform init ..." >&2
  "$TERRAFORM" init >/dev/null || "$TERRAFORM" init
fi

# workspace 与 stack 一一对应。default 是 terraform 内置的，不需要创建，
# 但也要显式 select —— 保持"每次调用都确定在哪个 workspace"这一不变式。
#
# 例外：`workspace` 子命令本身不自动 select。否则 `workspace delete x` 会先切到 x
# 再执行删除，永远撞上 "You cannot delete the currently active workspace"。
# 删工作区请显式指定：STACK=x scripts/tf.sh workspace delete x
if [ "${1:-}" != "workspace" ]; then
  if [ "$STACK" != "default" ] && \
     ! "$TERRAFORM" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -qx -- "$STACK"; then
    echo "  [tf.sh] 新建 workspace: $STACK" >&2
    "$TERRAFORM" workspace new "$STACK" >/dev/null
  fi
  "$TERRAFORM" workspace select "$STACK" >/dev/null
fi

exec "$TERRAFORM" "$@"
