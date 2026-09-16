#!/bin/bash
# esrally 客户端启动初始化：挂盘 -> 写入 ES 目标地址 -> 准备工作目录（不自动跑压测）
set -euo pipefail

DATA_DIR=${data_dir}
OSS_BUCKET=${oss_bucket}
OSS_PREFIX=${oss_prefix}
ES_HOSTS=${es_hosts}
ES_PORT=${es_port}
RALLY_BIN=${rally_bin}
ADMIN_PASS=${es_password}

LOG=/var/log/rally-init.log
exec > >(tee -a "$LOG") 2>&1
echo "=== rally init start $(date) ==="

# ---------- 1. 挂载数据盘 ----------
# 与 ES 节点同一套逻辑：取非系统盘整盘，先卸掉 cloud-init 可能做的 /mnt 自动挂载
# 数据盘识别：**不能**写死排除 vda —— 新一代实例（g8y 等第 7 代+ ARM）的系统盘
# 也是 NVMe 设备（nvme0n1），按名字排除会把系统盘当成数据盘挂到 /data，
# mount 直接报 busy 且数据写进系统盘。正确做法：先解析根分区所在的整盘再排除。
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || echo /dev/vda1)"
ROOT_DISK="$${ROOT_SRC%p[0-9]*}"
DISK="$(lsblk -dn -o NAME,TYPE | awk -v rd="$ROOT_DISK" '$2=="disk" && "/dev/"$1 != rd {print "/dev/"$1}' | head -1)"
echo "根分区所在盘: $ROOT_DISK；数据盘: $${DISK:-无}"

if [ -n "$DISK" ] && mountpoint -q /mnt 2>/dev/null; then
  umount /mnt 2>/dev/null || true
fi

# NVMe 分区名是 /dev/nvmeXn1p1（不是 /dev/nvmeXn11），老式盘是 /dev/vdb1。
# 自动探测第一个分区设备名，两种命名都能正确处理。
# 末尾 || true 是必须的：未分区时 grep 无匹配会返回 1，而
# PART="$(first_part ...)" 是简单赋值，set -e 下会直接结束整个脚本。
first_part() { # $1=DISK → 输出第一个分区设备路径（无分区则空）
  lsblk -lnpo NAME,TYPE "$${1}" 2>/dev/null | grep ' part' | head -1 | cut -d' ' -f1 || true
}
PART="$(first_part "$DISK")"
if [ -n "$DISK" ] && ! blkid "$DISK" >/dev/null 2>&1 && [ -z "$PART" ]; then
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary ext4 1MiB 100%
  sleep 2
  PART="$(first_part "$DISK")"
  mkfs.ext4 -F "$PART"
fi

mkdir -p "$DATA_DIR"
if [ -n "$DISK" ]; then
  DEV="$DISK"
  [ -n "$PART" ] && DEV="$PART"
  if ! mountpoint -q "$DATA_DIR"; then
    mount "$DEV" "$DATA_DIR"
    grep -q "$DATA_DIR" /etc/fstab || echo "$DEV $DATA_DIR ext4 defaults,noatime 0 0" >> /etc/fstab
  fi
fi

mkdir -p "$DATA_DIR"/{tracks,results,corpus,logs,scripts}

# ---------- 1.5 铺设语料 ----------
# 镜像里烘焙了 /opt/rally-corpus（见 build-image.sh --with-corpus）。
# 不能直接烘焙到 /data：数据盘在下面才挂载，会遮住镜像内容，所以开机时复制过去。
# 语料必须离线预置 —— track 定义默认走 github、语料走 GCS(Google Cloud Storage)，
# 国内 ECS 两者都拉不到，esrally 会直接起不来。
if [ -d /opt/rally-corpus/benchmarks ]; then
  if [ ! -f "$DATA_DIR/benchmarks/.corpus-ready" ]; then
    echo "铺设语料：/opt/rally-corpus -> $DATA_DIR/benchmarks"
    mkdir -p "$DATA_DIR/benchmarks"
    cp -a /opt/rally-corpus/benchmarks/. "$DATA_DIR/benchmarks/"
    touch "$DATA_DIR/benchmarks/.corpus-ready"
  fi
  echo "语料就绪："
  du -sh "$DATA_DIR/benchmarks" 2>/dev/null || true
  ls "$DATA_DIR/benchmarks/tracks/" 2>/dev/null | sed 's/^/  track: /' || true
  ls "$DATA_DIR/benchmarks/data/" 2>/dev/null | sed 's/^/  data:  /' || true
else
  echo "WARN: 镜像内无 /opt/rally-corpus，esrally 将尝试联网下载语料（国内大概率失败）"
  echo "      解决办法：重建 rally 镜像并加 --with-corpus（make image-rally WITH_CORPUS=1）"
fi

# ---------- 2. 写入目标地址 ----------
IFS=',' read -ra HOST_ARR <<< "$ES_HOSTS"
TARGETS=""
for h in "$${HOST_ARR[@]}"; do
  [ -z "$h" ] && continue
  TARGETS="$${TARGETS}http://$${h}:$${ES_PORT},"
done
TARGETS=$${TARGETS%,}
echo "$TARGETS" > /etc/es-targets.conf
echo "target-hosts: $TARGETS"

# ---------- 3. 环境自检 ----------
"$RALLY_BIN" --version || echo "WARN: esrally not found at $RALLY_BIN"
nproc
free -g | head -2

# ---------- 4. 记录 OSS 归档目标 ----------
cat > /etc/es-oss.conf <<EOF
OSS_BUCKET=$OSS_BUCKET
OSS_PREFIX=$OSS_PREFIX
ADMIN_PASS=$ADMIN_PASS
EOF
chmod 600 /etc/es-oss.conf

echo "=== rally init done ==="
echo "下一步：make bench MATRIX=<file> 触发压测"
