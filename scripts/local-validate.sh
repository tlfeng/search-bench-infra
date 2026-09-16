#!/bin/bash
# 在本地 Docker 容器里免费验证 install.sh（阶段 1~2 的镜像构建逻辑）。
#
# 为什么值得做：建镜像要起临时实例（花钱 + 15~25 分钟一轮），而这套脚本第一次跑必然要改几轮。
# 用容器先在本地把「依赖、下载、目录、账号、语料烘焙」这些逻辑验掉，
# 云上那一轮就大概率一次过，能省掉多次构建的钱和时间。
#
# 容器与目标环境的一致性：
#   - 平台用 linux/arm64（Apple Silicon 原生），与阿里云 ARM 机器同为 aarch64；
#   - 基础镜像用 rockylinux:9（≈ RHEL9，Python 3.9），与目标 OS 同世代。
#     注意 Alpine/Debian 走的是另一条分支，验证价值低。
#
# 用法：
#   ./scripts/local-validate.sh --role rally --with-corpus
#   ./scripts/local-validate.sh --role es --engine elasticsearch
#   ./scripts/local-validate.sh --role es --engine easysearch --version 2.4.0-2963
#   ./scripts/local-validate.sh --role all
#   ./scripts/local-validate.sh --role rally --keep      # 失败时保留容器，便于登进去查
set -uo pipefail

ROLES=""
ENGINE="elasticsearch"
VERSION=""
ARCH="aarch64"
IMAGE="rockylinux:9"
WITH_CORPUS=0
CORPUS_PKG=""
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLES="$2"; shift 2;;
    --engine) ENGINE="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --with-corpus) WITH_CORPUS=1; shift 1;;
    --corpus-pkg) CORPUS_PKG="$2"; shift 2;;
    --keep) KEEP=1; shift 1;;
    -h|--help) sed -n '2,25p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "$ROLES" ] || ROLES="rally"

# 找到 docker CLI（Docker Desktop 的 CLI 不一定在 PATH 里）
if ! command -v docker >/dev/null 2>&1; then
  for d in /usr/local/bin /opt/homebrew/bin /Applications/Docker.app/Contents/Resources/bin; do
    [ -x "$d/docker" ] && PATH="$d:$PATH" && export PATH && break
  done
fi
command -v docker >/dev/null 2>&1 || { echo "ERROR: 找不到 docker CLI" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker 守护进程未运行（先启动 Docker Desktop）" >&2; exit 1; }

case "$ARCH" in
  aarch64|arm64) PLATFORM="linux/arm64"; PKG_ARCH="aarch64";;
  x86_64|amd64)  PLATFORM="linux/amd64"; PKG_ARCH="x86_64";;
  *) echo "不支持的架构 $ARCH" >&2; exit 1;;
esac

[ -n "$CORPUS_PKG" ] || CORPUS_PKG="$ROOT/corpus/geonames-corpus.tar.gz"

# 结果收集：用计数器 + 名字串，避免 macOS bash 3.2 空数组 + set -u 的 unbound variable 坑
TOTAL=0
FAILS=0
FAILED_NAMES=""
pass() { TOTAL=$((TOTAL+1)); echo "    ✅ $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILS=$((FAILS+1)); FAILED_NAMES="$FAILED_NAMES
$1"; echo "    ❌ $1"; }
chk()  { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

run_role() {
  local role="$1"
  local cname="esbench-lv-$role"
  local rc=0

  echo
  echo "=============================================================="
  echo "  验证 role=$role  engine=$ENGINE  arch=$ARCH  镜像=$IMAGE"
  echo "=============================================================="

  FAILS_BEFORE=$FAILS
  SKIP_USERS_CHECK=0
  docker rm -f "$cname" >/dev/null 2>&1 || true
  docker run -d --name "$cname" --platform "$PLATFORM" "$IMAGE" sleep infinity >/dev/null \
    || { echo "  容器启动失败"; return 1; }

  docker cp "$ROOT/scripts/install.sh" "$cname:/root/install.sh" >/dev/null

  # 密码按引擎取：easysearch 的策略要求 >=9 位（Qwer@123 会被拒），
  # 必须与 install.sh / Makefile 的约定一致，否则验证结果会误导人。
  local engine_pass="Qwer@123"
  [ "$ENGINE" = "easysearch" ] && engine_pass="Qwer@1234"
  local args="--role $role --arch $PKG_ARCH --engine $ENGINE --es-pass $engine_pass"
  [ -n "$VERSION" ] && args="$args --version $VERSION"

  if [ "$role" = "rally" ] && { [ "$WITH_CORPUS" = "1" ] || [ "$CORPUS_PKG" != "" ]; }; then
    if [ -f "$CORPUS_PKG" ]; then
      echo "  · 拷入语料包 $(basename "$CORPUS_PKG") ($(du -h "$CORPUS_PKG" | cut -f1))"
      docker cp "$CORPUS_PKG" "$cname:/root/$(basename "$CORPUS_PKG")" >/dev/null
      args="$args --corpus-pkg /root/$(basename "$CORPUS_PKG")"
    else
      echo "  WARN: 语料包不存在 $CORPUS_PKG，跳过语料部分"
    fi
  fi

  echo "  · 执行：install.sh $args"
  echo "  ------------------------------------------------"
  docker exec "$cname" bash -lc "chmod +x /root/install.sh && /root/install.sh $args" 2>&1 \
    | sed 's/^/    | /'
  rc=${PIPESTATUS[0]}
  echo "  ------------------------------------------------"
  echo "  install.sh 退出码：$rc"
  [ "$rc" = "0" ] && pass "install.sh 执行成功" || fail "install.sh 执行成功（exit=$rc）"

  # ---------- 按角色的校验点 ----------
  if [ "$role" = "rally" ]; then
    chk "esrally 可执行"        "docker exec '$cname' test -x /opt/esrally/bin/esrally"
    chk "esrally 版本可打印"    "docker exec '$cname' /opt/esrally/bin/esrally --version"
    chk "~/.rally 指向 /data/rally" "docker exec '$cname' sh -c 'test -L /root/.rally && [ \"\$(readlink /root/.rally)\" = \"/data/rally\" ]'"
    chk "Python >= 3.9（esrally 2.12 硬要求）" \
        "docker exec '$cname' python3 -c 'import sys; sys.exit(0 if sys.version_info>=(3,9) else 1)'"
    if docker exec "$cname" test -d /opt/rally-corpus/benchmarks 2>/dev/null; then
      chk "语料：track 定义存在" "docker exec '$cname' test -f /opt/rally-corpus/benchmarks/tracks/geonames/track.json"
      chk "语料：数据文件存在"   "docker exec '$cname' test -f /opt/rally-corpus/benchmarks/data/geonames/documents-2.json.bz2"
      chk "语料：sha256 清单校验通过" \
          "docker exec '$cname' sh -c 'cd /opt/rally-corpus && sha256sum -c benchmarks/MANIFEST.sha256'"
    fi
  else
    local bin="elasticsearch"
    [ "$ENGINE" = "easysearch" ] && bin="easysearch"
    chk "引擎 $bin 已就位"      "docker exec '$cname' test -x /opt/es/bin/$bin"
    if [ "$ENGINE" = "easysearch" ]; then
      chk "配置文件是 easysearch.yml" "docker exec '$cname' test -f /opt/es/config/easysearch.yml"
      chk "未误用 elasticsearch.yml"  "docker exec '$cname' sh -c 'test ! -f /opt/es/config/elasticsearch.yml'"
      # 正确键名是 security.ssl.http.enabled（曾误写 security.http.ssl.enabled，属无效配置）
      chk "security.ssl.http.enabled: false（rally 走明文）" \
          "docker exec '$cname' grep -q '^security.ssl.http.enabled: false' /opt/es/config/easysearch.yml"
      chk "JDK21 已就位（发布包不带，由 initialize.sh 下载）" \
          "docker exec '$cname' /opt/es/jdk/bin/java -version"
      chk "证书已生成（transport ssl 必需）" \
          "docker exec '$cname' sh -c 'ls /opt/es/config/instance.crt /opt/es/config/ca.crt'"
      chk "admin 密码已按传入值重置（user.yml 哈希非包内默认值）" \
          "docker exec '$cname' sh -c '! grep -q "GNHStWSkQzhP9LnUbCVv2O2aFx67vXcFHcQvqC" /opt/es/config/security/user.yml'"
      SKIP_USERS_CHECK=1
    else
      chk "配置文件是 elasticsearch.yml" "docker exec '$cname' test -f /opt/es/config/elasticsearch.yml"
    fi
    chk "es 用户已创建"          "docker exec '$cname' id es"
    chk "jvm.options.d 堆配置"    "docker exec '$cname' grep -q '^-Xmx16g' /opt/es/config/jvm.options.d/heap.options"
    # 认证文件必须能被 es 用户读到，否则启动后连不上（root 建的 600 文件就会踩这个）。
    # 仅 ES 有 *users* 文件；easysearch 用 config/security/user.yml，上面已单独检查。
    if [ "$SKIP_USERS_CHECK" != "1" ]; then
      chk "users 文件存在"          "docker exec '$cname' sh -c 'ls /opt/es/config/*users*'"
      chk "users 文件对 es 用户可读" \
          "docker exec '$cname' sh -c 'f=\$(ls /opt/es/config/*users* 2>/dev/null | head -1); [ -n \"\$f\" ] && su -s /bin/bash es -c \"test -r \$f\"'"
    fi
  fi

  if [ "$KEEP" = "1" ] && { [ "$rc" != "0" ] || [ "$FAILS_BEFORE" != "$FAILS" ]; }; then
    echo
    echo "  --keep：容器 $cname 已保留。进容器排查："
    echo "    docker exec -it $cname bash"
    echo "  用完清理：docker rm -f $cname"
  else
    docker rm -f "$cname" >/dev/null 2>&1 || true
  fi
  return $rc
}

for r in $(echo "$ROLES" | tr ',' ' '); do
  case "$r" in
    rally|es) run_role "$r";;
    all) run_role rally; run_role es;;
    *) echo "unknown role: $r" >&2; exit 1;;
  esac
done

echo
echo "=============================================================="
echo "  汇总"
echo "=============================================================="
echo "  共 $TOTAL 项检查"
if [ "$FAILS" = "0" ]; then
  echo "  ✅ 全部通过 —— 可以进入云上构建"
  exit 0
fi
echo "  ❌ 失败 $FAILS 项，需要修完再上云："
printf '%s\n' "$FAILED_NAMES" | sed '/^$/d' | sed 's/^/     - /'
exit 1
