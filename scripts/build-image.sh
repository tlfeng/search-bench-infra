#!/bin/bash
# 构建自定义镜像：起临时实例 -> 安装 -> 打镜像 -> 销毁临时实例
#
# 前置：已安装 terraform 与 aliyun CLI，且 aliyun 已配置 AK。
#
# 用法：
#   ./build-image.sh --role es    --arch x86_64 --instance-type ecs.g8i.2xlarge
#   ./build-image.sh --role rally --arch x86_64 --instance-type ecs.g8i.xlarge
#   ./build-image.sh --role es    --arch aarch64 --instance-type ecs.g8y.2xlarge --es-pkg-url <url>
#
# 输出：打印新镜像 ID，填回 terraform.tfvars 的 es_image_id / rally_image_id
set -euo pipefail

ROLE=""; ARCH=""; INSTANCE_TYPE=""; ES_PKG_URL=""; ENGINE="elasticsearch"; VERSION=""
ES_PASS="Qwer@1234"    # 默认 admin 密码（两引擎统一 9 位），可用 --es-pass 覆盖
ES_CHANNEL="stable"    # --es-channel stable|snapshot（easysearch 用）
ES_BUNDLE=0            # --es-bundle：easysearch 用自带 JDK 的 bundle 包
IMAGE_NAME_PREFIX="esbench"
FORCE="${FORCE:-0}"    # FORCE=1：跳过「同名镜像已存在」查重，强制重建（名字追加时间戳后缀防撞名）
BASE_IMAGE_REGEX="^aliyun_4_(x64|arm64)_20G_alibase_[0-9]{8}[.]vhd$"   # 可用 --base-image-regex 覆盖为 ^rockylinux_9 等
CORPUS_PKG=""          # --with-corpus <tar.gz>：把 esrally 语料烘焙进镜像
KEEP_ON_FAIL="${KEEP_ON_FAIL:-0}"   # KEEP_ON_FAIL=1 或 --keep-on-failure：失败时保留临时实例，便于登进去排查
SYSTEM_DISK_SIZE=40    # --system-disk-size：构建实例的系统盘大小。**镜像大小 = 这个值**，
                       # 必须与运行期 system_disk_size 一致，否则会报 InvalidSystemDiskSize.LessThanImageSize

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2;;
    --es-pkg-url) ES_PKG_URL="$2"; shift 2;;
    --es-pass) ES_PASS="$2"; shift 2;;
    --es-channel) ES_CHANNEL="$2"; shift 2;;
    --es-bundle) ES_BUNDLE=1; shift 1;;
    --engine) ENGINE="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --image-name) IMAGE_NAME_PREFIX="$2"; shift 2;;
    --base-image-regex) BASE_IMAGE_REGEX="$2"; shift 2;;
    --with-corpus) CORPUS_PKG="$2"; shift 2;;
    --keep-on-failure) KEEP_ON_FAIL=1; shift 1;;
    --force) FORCE=1; shift 1;;
    --system-disk-size) SYSTEM_DISK_SIZE="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[ -n "$ROLE" ] && [ -n "$ARCH" ] && [ -n "$INSTANCE_TYPE" ] || {
  echo "需要 --role / --arch / --instance-type" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 语料包必须真实存在，否则等到 scp 才失败就白起了实例
if [ -n "$CORPUS_PKG" ] && [ ! -f "$CORPUS_PKG" ]; then
  echo "ERROR: --with-corpus 指定的文件不存在：$CORPUS_PKG" >&2
  echo "       先执行：./scripts/prepare-corpus.sh --track geonames" >&2
  exit 1
fi

# 注入 terraform 需要的凭据：从 ~/.aliyun/config.json 读取，只存在内存
# （脚本会直接调用 terraform，绕过了 Makefile 的注入，必须在这里补上）
# 无论成功失败都清理临时资源 —— 之前 apply 中途失败会留下 VPC/密钥对，
# 下次再跑就撞 KeyPair.AlreadyExist。用 trap 兜底。
CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  [ -d "$BUILD_DIR" ] || return 0
  # 失败时默认也清理（避免留下 VPC/实例持续计费）；
  # 要登进去排查就用 --keep-on-failure，脚本会打印实例 IP 并保留资源。
  if [ "$KEEP_ON_FAIL" = "1" ]; then
    echo
    echo "=== 保留临时资源（--keep-on-failure）==="
    echo "  排查：cd $BUILD_DIR && terraform output -raw public_ip"
    echo "  销毁：cd $BUILD_DIR && terraform destroy -auto-approve   <-- 别忘，实例在计费"
    return 0
  fi
  echo "=== 清理临时资源（trap）==="
  ( cd "$BUILD_DIR" && terraform destroy -auto-approve ) 2>&1 | tail -6
}
trap cleanup EXIT INT TERM

if [ -f "$HERE/tf-env.sh" ]; then
  . "$HERE/tf-env.sh"
elif [ -z "${ALICLOUD_ACCESS_KEY:-}" ]; then
  echo "ERROR: 既没有 $HERE/tf-env.sh，也没有 ALICLOUD_ACCESS_KEY 环境变量" >&2
  echo "       请先执行：aliyun configure" >&2
  exit 1
fi
# 镜像命名规则的唯一事实来源（image.sh fix-names 也用它，保证两边一致）
# shellcheck disable=SC1091
. "$HERE/image-name.sh"
ROOT="$(dirname "$HERE")"
# 地域与可用区沿用主配置：ARM 机型并非每个可用区都有货，
# 构建实例也必须落在有货的可用区，否则 create 会失败
TFV="$ROOT/terraform/terraform.tfvars"
if [ -f "$TFV" ]; then
  # 注意：BSD grep(macOS) 不认 \s，要用 POSIX 字符类 [[:space:]]
  : "${REGION:=$(sed -nE 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"(.*)".*/\1/p' "$TFV" | head -1)}"
  : "${ZONE_ID:=$(sed -nE 's/^[[:space:]]*zone_id[[:space:]]*=[[:space:]]*"(.*)".*/\1/p' "$TFV" | head -1)}"
fi

SUFFIX="$(date +%m%d%H%M%S)"
# 构建工作区必须带唯一后缀：它既是下面 rm -rf 的对象，也各自持有一份独立 state。
# 不带后缀时，两个并行的 make image-es / image-rally（或 FORCE=1 重跑）会互相删掉
# 对方的目录、并共用同一份 terraform state —— 报出来的错完全看不懂（曾经踩过）。
BUILD_DIR="$ROOT/.build-image-$ROLE-$ARCH-$SUFFIX"
# 确定性镜像名：唯一对应「角色+引擎/esrally+版本+架构」组合，不带时间戳——
# 这让构建前按名字查重成为可能（见下）；FORCE=1 重建时补时间戳后缀防撞名。
# 命名规则统一在 scripts/image-name.sh（compose_image_name），
# rally 的版本即 esrally 版本（默认 2.12.0，与 install.sh 的 RALLY_VERSION 默认一致）。
IMAGE_NAME=$(compose_image_name "$IMAGE_NAME_PREFIX" "$ROLE" "$ENGINE" "$VERSION" "$ARCH" "$CORPUS_PKG")

# 架构命名要分两套：
#   阿里云镜像(provider architecture 字段) -> arm64 / x86_64
#   引擎 tar.gz 的包名                      -> aarch64 / x86_64
case "$ARCH" in
  aarch64|arm64) TF_ARCH="arm64" ;;
  x86_64|amd64)  TF_ARCH="x86_64" ;;
  *) echo "ERROR: 不支持的架构 $ARCH" >&2; exit 1 ;;
esac
PKG_ARCH="$ARCH"

# 构建前查重：同名可用镜像已存在就跳过——镜像建一次长期复用，
# 重复构建只是白白多付快照存储、再多一个分不清的 ID。
# FORCE=1 跳过查重强制重建（镜像名会追加时间戳后缀防撞名）。
if [ "$FORCE" != "1" ]; then
  EXISTING=$(aliyun ecs DescribeImages --RegionId "${REGION:-cn-hangzhou}" \
               --ImageName "$IMAGE_NAME" 2>/dev/null \
             | jq -r --arg n "$IMAGE_NAME" \
                 '[.Images.Image[]? | select(.ImageName == $n and .Status == "Available")][0].ImageId // empty')
  if [ -n "$EXISTING" ]; then
    echo "=== 同名可用镜像已存在，跳过构建 ==="
    echo "  $IMAGE_NAME -> $EXISTING"
    echo "  tfvars 保持不变；要强制重建：FORCE=1 make image-es / image-rally"
    exit 0
  fi
  echo "  无同名可用镜像（${IMAGE_NAME}），开始构建"
fi

echo "=== 1/6 准备构建工作区 ==="
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cp "$HERE"/install.sh "$BUILD_DIR/"

cat > "$BUILD_DIR/main.tf" <<EOF
terraform {
  required_version = ">= 1.5"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.220"
    }
  }
}

variable "instance_type" { type = string }
variable "arch" { type = string }
variable "zone_id" { type = string }
variable "public_key" { type = string }
variable "vpc_cidr" {
  type    = string
  default = "172.31.0.0/16"
}
variable "vswitch_cidr" {
  type    = string
  default = "172.31.1.0/24"
}
variable "base_image_regex" { type = string }
variable "system_disk_size" { type = number }
variable "region" { type = string }

provider "alicloud" {
  region = var.region
}

resource "alicloud_vpc" "b" {
  vpc_name   = "imgbuild-vpc-$SUFFIX"
  cidr_block = var.vpc_cidr
}

resource "alicloud_vswitch" "b" {
  vpc_id     = alicloud_vpc.b.id
  cidr_block = var.vswitch_cidr
  zone_id    = var.zone_id
}

resource "alicloud_security_group" "b" {
  security_group_name = "imgbuild-sg-$SUFFIX"
  vpc_id              = alicloud_vpc.b.id
}

resource "alicloud_security_group_rule" "b" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  security_group_id = alicloud_security_group.b.id
  cidr_ip           = "0.0.0.0/0"
  priority          = 1
}

resource "alicloud_key_pair" "b" {
  key_pair_name = "imgbuild-key-$SUFFIX"
  public_key    = var.public_key
}

# 基础镜像：默认 Alibaba Cloud Linux 3（最省资源）。
# 注意：镜像名里架构写作 x64 / arm64，不含 "_64" 字面串，正则别写成 ".*_64"。
data "alicloud_images" "base" {
  owners       = "system"
  name_regex   = var.base_image_regex
  architecture = var.arch
  most_recent  = true
}

resource "alicloud_instance" "b" {
  instance_name              = "imgbuild-$ROLE-$SUFFIX"
  instance_type              = var.instance_type
  image_id                   = data.alicloud_images.base.images[0].id
  availability_zone          = var.zone_id
  vswitch_id                 = alicloud_vswitch.b.id
  security_groups            = [alicloud_security_group.b.id]
  key_name                   = alicloud_key_pair.b.key_pair_name
  instance_charge_type       = "PostPaid"
  # 按流量计费，入方向（下载 ES 包）免费；带宽峰值不计费，开大只加快下载
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = 100
  system_disk_category       = "cloud_essd"
  system_disk_size           = var.system_disk_size
}

output "public_ip" { value = alicloud_instance.b.public_ip }
output "instance_id" { value = alicloud_instance.b.id }
output "base_image_id" { value = data.alicloud_images.base.images[0].id }
EOF

# 公钥自动探测：不同机器可能只有 ed25519 或只有 rsa
PUBKEY_FILE="${SSH_PUBKEY:-}"
if [ -z "$PUBKEY_FILE" ]; then
  for c in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [ -f "$c" ] && PUBKEY_FILE="$c" && break
  done
fi
if [ ! -f "$PUBKEY_FILE" ]; then
  echo "ERROR: 找不到 SSH 公钥。请用 SSH_PUBKEY=/path/to/key.pub 指定" >&2
  exit 1
fi
echo "  使用公钥: $PUBKEY_FILE"

cat > "$BUILD_DIR/terraform.tfvars" <<EOF
region           = "${REGION:-cn-hangzhou}"
zone_id          = "${ZONE_ID:-cn-hangzhou-i}"
instance_type    = "$INSTANCE_TYPE"
arch             = "$TF_ARCH"
base_image_regex = "$BASE_IMAGE_REGEX"
system_disk_size = $SYSTEM_DISK_SIZE
public_key       = "$(cat "$PUBKEY_FILE")"
EOF

cd "$BUILD_DIR"
# 构建环境有自己的独立 state，不该继承主配置的 provider 缓存路径：
# Makefile 会 export TF_DATA_DIR（按 stack 隔离主环境用），继承下来会让并发的
# 镜像构建共享同一个 provider 目录，也可能在别人删 stack 时被一起清掉。
unset TF_DATA_DIR

echo "  terraform init..."
terraform init > /dev/null 2>&1 || terraform init
terraform apply -auto-approve

IP=$(terraform output -raw public_ip)
IID=$(terraform output -raw instance_id)
echo "临时实例: $IID @ $IP"

echo "=== 2/6 上传并执行安装脚本 ==="
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$IP" 'echo ok' >/dev/null 2>&1 && break
  sleep 5
done
scp -o StrictHostKeyChecking=no install.sh root@"$IP":/root/install.sh

INSTALL_ARGS="--role $ROLE --arch $PKG_ARCH --engine $ENGINE --es-pass $ES_PASS"
[ -n "$VERSION" ] && INSTALL_ARGS="$INSTALL_ARGS --version $VERSION"
[ -n "$ES_PKG_URL" ] && INSTALL_ARGS="$INSTALL_ARGS --es-pkg-url $ES_PKG_URL"
# easysearch 专属参数：channel（stable|snapshot）与 bundle 包（自带 JDK）
[ -n "$ES_CHANNEL" ] && INSTALL_ARGS="$INSTALL_ARGS --es-channel $ES_CHANNEL"
[ "$ES_BUNDLE" = "1" ] && INSTALL_ARGS="$INSTALL_ARGS --es-bundle"

# ---------- 3/6 上传语料（可选） ----------
# 语料必须放在 /opt 而不是 /data：运行期 userdata 会把数据盘挂到 /data，
# 挂载会遮住镜像里烘焙在 /data 下的内容。
# 烘焙与校验的实现放在 install.sh 的 --corpus-pkg 里，而不是这里内联 ——
# 这样同一段逻辑既能在云上构建时跑，也能在本地容器里免费验证。
if [ -n "$CORPUS_PKG" ]; then
  if [ "$ROLE" != "rally" ]; then
    echo "WARN: --with-corpus 仅对 --role rally 有意义，已忽略" >&2
  else
    echo "=== 3/6 上传语料 $(basename "$CORPUS_PKG") ==="
    REMOTE_PKG="/root/$(basename "$CORPUS_PKG")"
    scp -o StrictHostKeyChecking=no "$CORPUS_PKG" root@"$IP":"$REMOTE_PKG"
    INSTALL_ARGS="$INSTALL_ARGS --corpus-pkg $REMOTE_PKG"
  fi
fi

ssh -o StrictHostKeyChecking=no root@"$IP" "chmod +x /root/install.sh && /root/install.sh $INSTALL_ARGS"

echo "=== 4/7 停止实例（CreateImage 要求实例处于「已停止」状态，运行中会报错）==="
aliyun ecs StopInstance --RegionId "${REGION:-cn-hangzhou}" --InstanceId "$IID" >/dev/null 2>&1 || true
S=""
for i in $(seq 1 36); do
  S=$(aliyun ecs DescribeInstances --RegionId "${REGION:-cn-hangzhou}" \
       --InstanceIds "[\"$IID\"]" 2>/dev/null | jq -r '.Instances.Instance[0].Status')
  [ "$S" = "Stopped" ] && break
  sleep 5
done
[ "$S" = "Stopped" ] || { echo "ERROR: 实例未能停止（当前状态 ${S}）" >&2; exit 1; }
echo "  实例已停止"

echo "=== 5/7 打自定义镜像 ==="
CREATE_OUT=$(aliyun ecs CreateImage \
  --RegionId "${REGION:-cn-hangzhou}" \
  --InstanceId "$IID" \
  --ImageName "$IMAGE_NAME" \
  --Architecture "$TF_ARCH" \
  --Description "esbench $ROLE for $ARCH built $(date)" 2>&1) \
  || { echo "ERROR: CreateImage 失败：" >&2; echo "$CREATE_OUT" | tail -8 >&2; exit 1; }
NEW_IMAGE=$(echo "$CREATE_OUT" | jq -r '.ImageId // empty' 2>/dev/null)
if [ -z "$NEW_IMAGE" ]; then
  echo "ERROR: CreateImage 返回里没有 ImageId：" >&2
  echo "$CREATE_OUT" | tail -8 >&2
  exit 1
fi
echo "新镜像 ID: $NEW_IMAGE"

echo "=== 6/7 等待镜像可用 ==="
ST=""
for i in $(seq 1 60); do
  ST=$(aliyun ecs DescribeImages --RegionId "${REGION:-cn-hangzhou}" \
       --ImageId "$NEW_IMAGE" 2>/dev/null | jq -r '.Images.Image[0].Status')
  [ "$ST" = "Available" ] && break
  sleep 10
done
[ "$ST" = "Available" ] || { echo "WARN: 镜像 10 分钟内未到 Available（当前 ${ST}），可能仍在生成"; }
echo "镜像状态: $ST"

echo "=== 7/7 销毁临时实例 ==="
CLEANED=1
terraform destroy -auto-approve
cd - > /dev/null

{
  echo "# $(date)  $ROLE/$ARCH"
  echo "${ROLE}_image_id_${ARCH} = \"$NEW_IMAGE\""
} >> "$ROOT/image-ids.txt"

# 结构化台账：TSV（日期/角色/架构/引擎/版本/镜像ID/镜像名），供 make image-ls / image-use 使用。
# 这里刻意不加锁：以 O_APPEND 追加单条短行（远小于 PIPE_BUF）是原子写，
# 并发构建最多让两行的顺序互换，不会写出半行。真正需要原子性的是
# image.sh fix-names 的「读-改-写」，那一处已改成临时文件 + 原子 mv。
if [ "$ROLE" = "es" ]; then
  ENGINE_LABEL="$ENGINE"
  VERSION_LABEL="${VERSION:--}"
else
  ENGINE_LABEL="-"
  VERSION_LABEL="-"
  if [ -n "$CORPUS_PKG" ]; then VERSION_LABEL="corpus"; fi
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date '+%F %T')" "$ROLE" "$ARCH" "$ENGINE_LABEL" "$VERSION_LABEL" "$NEW_IMAGE" "$IMAGE_NAME" \
  >> "$ROOT/image-ids.txt"

echo
echo "完成。把下面这行填进 terraform/terraform.tfvars："
echo "  ${ROLE}_image_id = \"$NEW_IMAGE\""
echo "或直接切换：make image-use --id $NEW_IMAGE"
echo "（已追加到 image-ids.txt）"
