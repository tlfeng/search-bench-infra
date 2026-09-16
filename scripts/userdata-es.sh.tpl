#!/bin/bash
# ES 节点启动初始化。镜像内已固化引擎二进制，这里只做：挂盘 -> 写配置 -> 启动 -> 等健康
set -euo pipefail

NODE_INDEX=${node_index}
NODE_COUNT=${node_count}
HEAP_GB=${heap_gb}
ENGINE=${engine}
ENGINE_HOME=${engine_home}
DATA_DIR=${data_dir}
CLUSTER_NAME=${cluster_name}
ES_PORT=${es_port}
ES_IPS=${es_ips}
ES_TRANSPORT_PORT=${es_transport_port}
ADMIN_PASS=${es_password}

LOG=/var/log/es-init.log
exec > >(tee -a "$LOG") 2>&1
echo "=== es init start $(date) node=$${NODE_INDEX}/$${NODE_COUNT} ==="

# ---------- 1. 挂载数据盘 ----------
# 取非系统盘的整盘设备（阿里云系统盘通常是 vda）
# 数据盘识别：**不能**写死排除 vda —— 新一代实例（g8y 等第 7 代+ ARM）的系统盘
# 也是 NVMe 设备（nvme0n1），按名字排除会把系统盘当成数据盘挂到 /data，
# mount 直接报 busy 且数据写进系统盘。正确做法：先解析根分区所在的整盘再排除。
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || echo /dev/vda1)"
ROOT_DISK="$${ROOT_SRC%p[0-9]*}"
DISK="$(lsblk -dn -o NAME,TYPE | awk -v rd="$ROOT_DISK" '$2=="disk" && "/dev/"$1 != rd {print "/dev/"$1}' | head -1)"
echo "根分区所在盘: $ROOT_DISK；数据盘: $${DISK:-无}"

# Alibaba Cloud Linux / cloud-init 有时会把空数据盘自动格式化并挂到 /mnt。
# 若不管它，ES 的数据会落在 /mnt 而不是 DATA_DIR，后面所有路径假设都错。
if [ -n "$DISK" ] && mountpoint -q /mnt 2>/dev/null; then
  umount /mnt 2>/dev/null || true
fi

# NVMe 分区名是 /dev/nvmeXn1p1（不是 /dev/nvmeXn11），老式盘是 /dev/vdb1。
# 自动探测第一个分区设备名，两种命名都能正确处理。
# 末尾 || true 是必须的：未分区时 grep 无匹配返回 1，而
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

# ---------- 2. 写配置 ----------
CONF_DIR="$ENGINE_HOME/config"
mkdir -p "$DATA_DIR"
chown -R es:es "$DATA_DIR" 2>/dev/null || true

# 节点内网 IP 由 terraform 固定分配后注入（local.es_ips），开机即可知全量节点
IFS=',' read -ra IP_ARR <<< "$ES_IPS"
SEED_HOSTS=""
MASTER_NODES=""
for ip in "$${IP_ARR[@]}"; do
  [ -z "$ip" ] && continue
  SEED_HOSTS="$${SEED_HOSTS}\"$${ip}:$${ES_TRANSPORT_PORT}\","
done
SEED_HOSTS=$${SEED_HOSTS%,}
for i in $(seq 1 $${NODE_COUNT}); do
  MASTER_NODES="$${MASTER_NODES}\"es-node-$${i}\","
done
MASTER_NODES=$${MASTER_NODES%,}
# 兜底：若注入为空则退回本地
[ -z "$SEED_HOSTS" ] && SEED_HOSTS="\"127.0.0.1:$${ES_TRANSPORT_PORT}\""

# 配置文件名与二进制按引擎区分：easysearch 是 easysearch.yml / bin/easysearch，
# 写成 elasticsearch.yml 会导致配置不生效、集群起不来。
case "$ENGINE" in
  easysearch)
    CONF_FILE="$CONF_DIR/easysearch.yml"
    ES_BIN="$ENGINE_HOME/bin/easysearch"
    ;;
  *)
    CONF_FILE="$CONF_DIR/elasticsearch.yml"
    ES_BIN="$ENGINE_HOME/bin/elasticsearch"
    ;;
esac

# **追加**而不是覆盖：镜像里的配置带着引擎自身的关键设置
# （easysearch 的 security.enabled / transport ssl / 证书路径等），
# 用 cat > 覆盖会把这些抹掉，节点直接起不来。幂等：已写过就跳过。
if ! grep -q "^node.name: es-node-$${NODE_INDEX}$" "$CONF_FILE" 2>/dev/null; then
  cat >> "$CONF_FILE" <<EOF
cluster.name: $${CLUSTER_NAME}
node.name: es-node-$${NODE_INDEX}
path.data: $${DATA_DIR}
path.logs: $${DATA_DIR}/../logs
network.host: 0.0.0.0
http.port: $${ES_PORT}
discovery.seed_hosts: [$${SEED_HOSTS}]
cluster.initial_master_nodes: [$${MASTER_NODES}]
EOF
fi

# 安全项分引擎写：ES 用 xpack.* 前缀；
# easysearch 的安全配置沿用镜像构建时写入的 security.ssl.http.enabled: false，
# 这里不覆盖，避免写错前缀导致启动失败。
if [ "$ENGINE" != "easysearch" ]; then
  # ES 8.x 开启 security 后 bootstrap check 强制要求 transport 层启用 SSL，
  # 否则启动直接被拒（Transport SSL must be enabled if security is enabled）。
  # 用 elasticsearch-certutil 生成自签证书即可满足校验；http 层仍走明文（压测需要）。
  if [ ! -f "$CONF_DIR/elastic-certificates.p12" ]; then
    "$ENGINE_HOME/bin/elasticsearch-certutil" ca \
        --out "$CONF_DIR/elastic-stack-ca.p12" --pass "" >/dev/null 2>&1
    "$ENGINE_HOME/bin/elasticsearch-certutil" cert \
        --ca "$CONF_DIR/elastic-stack-ca.p12" --ca-pass "" \
        --out "$CONF_DIR/elastic-certificates.p12" --pass "" >/dev/null 2>&1
    chown es:es "$CONF_DIR"/*.p12 2>/dev/null || true
  fi
  cat >> "$CONF_FILE" <<EOF
xpack.security.enabled: true
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: elastic-certificates.p12
EOF
fi

# 堆大小：heap_gb<=0 时按机型内存自动取 50%（下限 1G，上限 31G）。
# 小机型（如 arm-debug 2C8G）沿用基线 16g 会直接 OOM（mmap 16GiB 失败），必须自适应。
if [ "$${HEAP_GB:-0}" -le 0 ] 2>/dev/null; then
  MEM_GB="$(free -g | awk '/^Mem:/{print $2}')"
  HEAP_GB=$(( MEM_GB / 2 ))
  [ "$${HEAP_GB}" -lt 1 ] && HEAP_GB=1
  [ "$${HEAP_GB}" -gt 31 ] && HEAP_GB=31
  echo "heap_gb 未指定 → 按内存 $${MEM_GB}G 自动设为 $${HEAP_GB}g"
fi
echo "堆设置: $${HEAP_GB}g"

mkdir -p "$CONF_DIR/jvm.options.d"
cat > "$CONF_DIR/jvm.options.d/heap.options" <<EOF
-Xms$${HEAP_GB}g
-Xmx$${HEAP_GB}g
EOF

# ---------- 3. 系统调优（压测必需） ----------
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-es.conf
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
ulimit -n 65535

# ---------- 4. 启动 ----------
# 用引擎对应的二进制，不要用 A || B 兜底：
# 那样在 A 存在但启动失败时会误切到 B，掩盖真正的错误。
if ! id es >/dev/null 2>&1; then
  echo "ERROR: 用户 'es' 不存在，ES 不允许以 root 运行" >&2
  exit 1
fi
if [ ! -x "$ES_BIN" ]; then
  echo "ERROR: 找不到可执行引擎: $ES_BIN" >&2
  exit 1
fi
su - es -c "$ES_BIN -d -p /tmp/es.pid"
echo "started: $ES_BIN"

# ---------- 5. 等待健康（最多 5 分钟） ----------
for i in $(seq 1 60); do
  if curl -sf -u "admin:$${ADMIN_PASS}" "http://127.0.0.1:$${ES_PORT}/_cluster/health" >/dev/null 2>&1; then
    echo "=== es up after $${i}0s ==="
    curl -s -u "admin:$${ADMIN_PASS}" "http://127.0.0.1:$${ES_PORT}/_cluster/health?pretty"
    exit 0
  fi
  sleep 10
done

echo "ERROR: es did not become healthy in 600s" >&2
exit 1
