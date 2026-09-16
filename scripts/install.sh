#!/bin/bash
# 镜像构建阶段执行：安装引擎与 esrally。构建完打镜像，之后每次开机直接用镜像。
#
# 用法：
#   ./install.sh --role es    --arch x86_64  [--engine elasticsearch] [--version 8.19.20]
#   ./install.sh --role rally --arch x86_64
set -euo pipefail

ROLE=""
ARCH=""
ENGINE="elasticsearch"
VERSION=""             # 留空则按引擎取默认：es=8.19.20，easysearch=2.4.0-2963
ES_PASS="Qwer@123"     # 与 185 环境一致的 admin 密码
ES_HOME="/opt/es"
RALLY_HOME="/opt/esrally"
ES_PKG_URL=""      # easysearch 等内部版本用它覆盖
RALLY_PKG_URL=""
CORPUS_PKG=""      # --corpus-pkg <tar.gz 在实例上的路径>：烘焙 esrally 语料
ES_CHANNEL="stable"  # --es-channel stable|snapshot
ES_BUNDLE=0          # --es-bundle：用自带 JDK 的 bundle 包（发布包本体不含 JDK）

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --engine) ENGINE="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --es-home) ES_HOME="$2"; shift 2;;
    --es-pkg-url) ES_PKG_URL="$2"; shift 2;;
    --es-pass) ES_PASS="$2"; shift 2;;
    --rally-pkg-url) RALLY_PKG_URL="$2"; shift 2;;
    --corpus-pkg) CORPUS_PKG="$2"; shift 2;;
    --es-channel) ES_CHANNEL="$2"; shift 2;;
    --es-bundle) ES_BUNDLE=1; shift 1;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[ -n "$ROLE" ] || { echo "--role es|rally required" >&2; exit 1; }
[ -n "$ARCH" ] || ARCH="$(uname -m)"

# 版本留空时按引擎取默认（easysearch 的版本串带 build 号，与 ES 不同）
if [ -z "$VERSION" ]; then
  case "$ENGINE" in
    easysearch) VERSION="2.4.0-2963" ;;
    *)          VERSION="8.19.20" ;;
  esac
fi

log() { echo "[install:$ROLE] $*"; }

# ---------- 包管理器封装（全局） ----------
# 逐个安装而不是一次装一串：任何一个包冲突只会影响它自己，不会拖垮整批。
# 背景：RHEL9 系基础镜像自带 curl-minimal，与 curl 包冲突，
# 一次装一串时整条 dnf 事务会回滚 —— 结果是"一个包都没装上"。
if   command -v dnf >/dev/null 2>&1;     then PM="dnf"
elif command -v yum >/dev/null 2>&1;     then PM="yum"
elif command -v apt-get >/dev/null 2>&1; then PM="apt-get"
else PM=""
fi

_MISSING_PKGS=""
pkg_install() {
  local p
  for p in "$@"; do
    if [ "$PM" = "apt-get" ]; then
      apt-get install -y -qq "$p" >/dev/null 2>&1 && continue
    elif [ -n "$PM" ]; then
      $PM install -y -q "$p" >/dev/null 2>&1 && continue
      $PM module install -y "$p" >/dev/null 2>&1 && continue
    fi
    _MISSING_PKGS="$_MISSING_PKGS $p"
  done
}

# ---------- 公共：系统依赖与调优 ----------
install_common() {
  [ "$PM" = "apt-get" ] && apt-get update -qq >/dev/null 2>&1

  PKGS="tar gzip wget jq sysstat numactl mdadm parted which procps-ng openssl"
  # openssl：easysearch 的 initialize.sh 生成证书必需；精简镜像/最小安装里可能没有
  #（本地容器实测：缺它会卡在证书生成，报 "openssl is not installed"）

  # curl 不放进批量列表：RHEL9 系基础镜像自带 curl-minimal，与 curl 包冲突，
  # 冲突会让**整条 dnf 事务回滚**——表现是"一个包都没装上"，再被 || true 掩盖成静默失败。
  # 实测：rockylinux:9 上就这么让 gcc 也没装上，最后卡在 pip 编译 C 扩展。
  command -v curl >/dev/null 2>&1 || PKGS="$PKGS curl"

  if [ -n "$PM" ]; then
    pkg_install $PKGS
    case "$ROLE" in
      rally) pkg_install python3 python3-pip python3-venv;;
      es)    pkg_install tar curl which procps-ng;;
    esac
  fi
  [ -n "$_MISSING_PKGS" ] && \
    log "WARN: 以下包没装上（通常表示已存在或与基础镜像自带包冲突）：$_MISSING_PKGS"

  # 必需命令校验——缺了要在后面以难懂的方式失败之前就报出来
  local miss=""
  for c in tar curl; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
  [ -n "$miss" ] && { echo "ERROR: 缺少必需命令：$miss" >&2; exit 1; }

  # ---- Rocky 特有：firewalld 与 SELinux 会挡住 ES 端口与数据目录 ----
  # 云上已有安全组做网络隔离，主机层再叠一层防火墙对压测只有干扰
  systemctl stop firewalld >/dev/null 2>&1 || true
  systemctl disable firewalld >/dev/null 2>&1 || true

  # SELinux 置为 permissive：ES 若装到 /opt 且数据目录在 /data，
  # enforcing 下会因上下文不对导致启动失败或无法写数据
  if command -v setenforce >/dev/null 2>&1 && [ -f /etc/selinux/config ]; then
    setenforce 0 >/dev/null 2>&1 || true
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
  fi

  # 压测相关内核参数（与 perf-env-guard 的固化项对齐）
  # 注意 mkdir：精简镜像/最小安装下 /etc/sysctl.d 可能不存在，
  # 直接 cat 会因 set -e 中断整个安装（本地容器验证就是这么抓出来的）
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-bench.conf <<'EOF'
vm.max_map_count=262144
vm.swappiness=1
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
EOF
  sysctl --system >/dev/null 2>&1 || true

  # 关闭透明大页（开机即生效）。同样先确保目录存在
  mkdir -p /etc/systemd/system
  cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled || true'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable disable-thp >/dev/null 2>&1 || true
}

# ---------- ES 节点 ----------
install_es() {
  log "install engine=$ENGINE arch=$ARCH version=$VERSION -> $ES_HOME"

  id es >/dev/null 2>&1 || useradd -m -s /bin/bash es
  mkdir -p "$ES_HOME"

  # 下载目录：**必须保留原始文件名**。
  # 曾经把包统一重命名成 engine.tar.gz 再校验，而 .sha512 清单里写的是原始文件名，
  # sha512sum -c 于是永远"找不到文件"——校验形同虚设（只打印一句 WARN 就继续）。
  DL_DIR="$(mktemp -d /tmp/engine-dl-XXXXXX)"
  PKG=""

  if [ -n "$ES_PKG_URL" ]; then
    URL="$ES_PKG_URL"
    PKG="$DL_DIR/$(basename "${URL%%\?*}")"
    [ "$(basename "$PKG")" != "/" ] || PKG="$DL_DIR/engine.tar.gz"
    log "download (custom) $URL"
    curl -fsSL -o "$PKG" "$URL" || { echo "下载失败: $URL" >&2; exit 1; }

  elif [ "$ENGINE" = "easysearch" ]; then
    # 官方发布地址规律（已实测 200）：
    #   https://release.infinilabs.com/easysearch/stable/easysearch-<版本>-linux-<amd64|arm64>.tar.gz
    # 注意：mac 包是 .zip（mac-arm64），与 Linux 的 .tar.gz 不同，别下错。
    case "$ARCH" in
      x86_64|amd64) EA="amd64" ;;
      aarch64|arm64) EA="arm64" ;;
      *) echo "easysearch: 不支持的架构 $ARCH" >&2; exit 1 ;;
    esac
    # 两种包形态：
    #   普通包  /<channel>/easysearch-<ver>-linux-<arch>.tar.gz          （不含 JDK）
    #   bundle  /<channel>/bundle/easysearch-<ver>-linux-<arch>-bundle.tar.gz （自带 JDK）
    # bundle 更省事：initialize.sh 检测到 $ES_HOME/jdk 就不再现拉 200MB 的 JDK21。
    if [ "$ES_BUNDLE" = "1" ]; then
      PKG="$DL_DIR/easysearch-${VERSION}-linux-${EA}-bundle.tar.gz"
      URL="https://release.infinilabs.com/easysearch/${ES_CHANNEL}/bundle/$(basename "$PKG")"
    else
      PKG="$DL_DIR/easysearch-${VERSION}-linux-${EA}.tar.gz"
      URL="https://release.infinilabs.com/easysearch/${ES_CHANNEL}/$(basename "$PKG")"
    fi
    log "download $URL"
    curl -fsSL -o "$PKG" "$URL" || { echo "下载失败: $URL" >&2; exit 1; }

  elif [ "$ENGINE" = "elasticsearch" ]; then
    PKG="$DL_DIR/elasticsearch-${VERSION}-linux-${ARCH}.tar.gz"
    URL="https://artifacts.elastic.co/downloads/elasticsearch/$(basename "$PKG")"
    log "download $URL"
    curl -fsSL -o "$PKG" "$URL" || { echo "下载失败: $URL" >&2; exit 1; }

  else
    echo "未知引擎 $ENGINE（支持 elasticsearch / easysearch）" >&2; exit 1
  fi

  # 校验（两家都提供同名 .sha512）。校验失败即中止 —— 宁可构建失败，
  # 也不要烘一个下载损坏的引擎镜像进去。
  if curl -fsSL -o "${PKG}.sha512" "${URL}.sha512" 2>/dev/null; then
    ( cd "$DL_DIR" && sha512sum -c "$(basename "$PKG").sha512" ) \
      || { echo "ERROR: $(basename "$PKG") sha512 校验失败" >&2; exit 1; }
    log "sha512 校验通过"
  else
    log "WARN: 官方未提供 .sha512，跳过完整性校验"
  fi

  # 解包到专属临时目录：既避免污染 /tmp，又能兼容两种包布局 ——
  #   ES 包有顶层目录（elasticsearch-<ver>/），
  #   easysearch 包**没有**顶层目录（bin/lib/config 直接摊在根上）。
  # 之前按名字 find 'easysearch-*' 找顶层目录，在 easysearch 上必然为空 → unpack failed。
  UNPACK="$(mktemp -d /tmp/engine-unpack-XXXXXX)"
  tar -xzf "$PKG" -C "$UNPACK"
  SRC="$UNPACK"
  if [ "$(find "$UNPACK" -maxdepth 1 -mindepth 1 | wc -l)" = "1" ] \
     && [ -d "$(find "$UNPACK" -maxdepth 1 -mindepth 1 -type d | head -1)" ]; then
    SRC="$(find "$UNPACK" -maxdepth 1 -mindepth 1 -type d | head -1)"
  fi
  cp -a "$SRC"/. "$ES_HOME"/
  rm -rf "$UNPACK" "$DL_DIR"

  # 目录约定与权限
  mkdir -p /data/es /data/logs
  chown -R es:es "$ES_HOME" /data

  # 默认堆（userdata 会按参数覆盖）
  mkdir -p "$ES_HOME/config/jvm.options.d"
  cat > "$ES_HOME/config/jvm.options.d/heap.options" <<'EOF'
-Xms16g
-Xmx16g
EOF

  if [ "$ENGINE" = "easysearch" ]; then
    # easysearch **没有** elasticsearch-users 那样的离线建号工具。
    # 官方路径是 bin/initialize.sh：下载 JDK21 到 $ES_HOME/jdk（发布包不带 JDK）、
    # 生成 ca/instance/admin 证书、初始化 security 并写入 admin 密码。
    # 支持 -s 静默模式 + EASYSEARCH_INITIAL_ADMIN_PASSWORD 环境变量指定密码。
    #
    # 注意：easysearch 的密码策略要求 >=9 位（须含大小写/数字/特殊字符），
    # Qwer@123 只有 8 位会被拒 —— 这是 EZ 侧密码与 ES 侧不同的硬原因。
    if [ "${#ES_PASS}" -lt 9 ]; then
      echo "ERROR: easysearch 的密码策略要求密码至少 9 位（当前 ${#ES_PASS} 位）" >&2
      echo "       须含大小写字母、数字与特殊字符。请用 --es-pass 传合规密码" >&2
      exit 1
    fi
    log "初始化 easysearch（initialize.sh -s：下载 JDK21 + 生成证书 + 写入 admin 密码）"
    # initialize.sh 要从外网拉 ~200MB 的 JDK21，耗时长且可能因网络抖动失败。
    # 输出落盘：成功时只回显尾部，失败时把日志尾部打出来，否则只知道 exit=1 无从排查。
    INIT_LOG="$ES_HOME/logs/initialize-run.log"
    mkdir -p "$ES_HOME/logs"
    # initialize.sh 依赖外网（拉 ~200MB 的 JDK21 + 插件清单），偶发网络抖动就会失败。
    # 云上构建一次失败 = 白花 0.2 元 + 等 20 分钟，所以这里自动重试。
    INIT_OK=0
    for attempt in 1 2 3; do
      if ( cd "$ES_HOME" && EASYSEARCH_INITIAL_ADMIN_PASSWORD="$ES_PASS" \
             bash bin/initialize.sh -s ) > "$INIT_LOG" 2>&1; then
        INIT_OK=1
        tail -4 "$INIT_LOG" | sed 's/^/    | /'
        log "easysearch 初始化完成（第 $attempt 次尝试）"
        break
      fi
      log "initialize.sh 第 $attempt 次尝试失败，$((attempt*20)) 秒后重试（日志尾部：）"
      tail -6 "$INIT_LOG" | sed 's/^/    | /' >&2
      sleep $((attempt*20))
    done
    [ "$INIT_OK" = "1" ] || {
      echo "ERROR: bin/initialize.sh 重试 3 次仍失败，完整日志 $INIT_LOG" >&2
      exit 1
    }

    [ -x "$ES_HOME/jdk/bin/java" ] || { echo "ERROR: JDK 未就位（$ES_HOME/jdk）" >&2; exit 1; }
    ls "$ES_HOME"/config/*.crt >/dev/null 2>&1 \
      || { echo "ERROR: 证书未生成" >&2; exit 1; }

    # rally 走明文 HTTP（与 ES 侧一致，避免 TLS 开销污染对比数据）。
    # 键名是 security.ssl.http.enabled —— 曾误写成 security.http.ssl.enabled，那是无效配置，
    # 结果 easysearch 仍走 HTTPS 自签证书，rally 连不上。
    sed -i 's/^security\.ssl\.http\.enabled:.*/security.ssl.http.enabled: false/' \
      "$ES_HOME/config/easysearch.yml"
    grep -q '^security.ssl.http.enabled: false' "$ES_HOME/config/easysearch.yml" \
      || echo 'security.ssl.http.enabled: false' >> "$ES_HOME/config/easysearch.yml"
    log "已关闭 HTTP TLS（security.ssl.http.enabled: false），rally 走明文 9200"
  else
    # elasticsearch：elasticsearch-users 可在集群未启动时写入 file realm，镜像阶段即可完成
    USERS_BIN="$ES_HOME/bin/elasticsearch-users"
    if [ -x "$USERS_BIN" ]; then
      "$USERS_BIN" useradd admin -p "$ES_PASS" -r superuser 2>/dev/null \
        && log "created user admin (superuser)" \
        || log "admin 用户已存在或工具不支持，请启动后确认"
      "$USERS_BIN" roles admin -a superuser 2>/dev/null || true
    else
      log "WARN: 未找到 elasticsearch-users 工具，认证需启动后手动配置"
    fi
  fi

  # 最后再 chown 一次：users 工具是在前面的 chown 之后由 root 执行的，
  # 它写出的 config/*_users 文件归 root 且常是 600 —— ES 以 es 用户运行会读不到，
  # 表现为启动后 401。这里统一把属主交回 es。
  chown -R es:es "$ES_HOME" /data 2>/dev/null || true

  log "engine installed"
}

# ---------- 编译环境 ----------
# esrally 的依赖 psutil / yappi 在部分架构+Python 组合下没有预编译 wheel，
# pip 会退回源码编译 —— 此时缺 gcc 或 Python 头文件就会失败。
# 头文件包名随解释器版本变化（python39-devel / python3.11-devel / python3-devel），
# 所以不猜包名，而是按「头文件是否真的出现」来判定成功。
ensure_build_env() {
  local py="$1"
  command -v gcc  >/dev/null 2>&1 || pkg_install gcc
  command -v make >/dev/null 2>&1 || pkg_install make

  _has_py_headers() {
    "$py" -c 'import sysconfig,os,sys; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_paths()["include"],"Python.h")) else 1)' >/dev/null 2>&1
  }
  if ! _has_py_headers; then
    local v maj min
    v="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    maj="${v%%.*}"; min="${v##*.}"
    pkg_install "python${maj}${min}-devel" "python${v}-devel" python3-devel
  fi

  if ! _has_py_headers; then
    log "WARN: 未找到 Python 头文件（$("$py" -V 2>&1)），若 pip 需要源码编译会失败"
  fi
  command -v gcc >/dev/null 2>&1 && log "编译环境就绪：$(gcc --version | head -1)" \
                                   || log "WARN: 无 gcc"
}

# ---------- Python 解释器选择 ----------
# esrally 2.12.0 要求 Python >= 3.9；而 RHEL8 世代（含 Alibaba Cloud Linux 3）
# 系统 python3 只有 3.6.8，直接 `pip install esrally` 会被 Requires-Python 挡下。
# 这里按「先找已装的够新解释器，再从 dnf 模块yum 装一个」的顺序兜底。
PY_MIN="3.9"

_py_ok() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || return 1
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' >/dev/null 2>&1
}

pick_python() {
  local c
  for c in python3 python3.13 python3.12 python3.11 python3.10 python3.9 /usr/bin/python3; do
    _py_ok "$c" && { echo "$c"; return 0; }
  done

  # 已装的不够新 —— 尝试从发行版仓库装一个（RHEL8 的 python39 模块即为此场景）
  if command -v dnf >/dev/null 2>&1; then
    for spec in python3.11 python3.10 python39 python3.9; do
      dnf install -y -q "$spec" >/dev/null 2>&1 \
        || dnf module install -y "$spec" >/dev/null 2>&1 \
        || dnf module enable -y "$spec" >/dev/null 2>&1 || true
      for c in python3.11 python3.10 python3.9; do
        _py_ok "$c" && { echo "$c"; return 0; }
      done
    done
  elif command -v yum >/dev/null 2>&1; then
    for spec in python3.11 python3.10 python39 python3.9; do
      yum install -y -q "$spec" >/dev/null 2>&1 || yum module install -y "$spec" >/dev/null 2>&1 || true
      for c in python3.11 python3.10 python3.9; do
        _py_ok "$c" && { echo "$c"; return 0; }
      done
    done
  fi
  return 1
}

# ---------- esrally 客户端 ----------
install_rally() {
  log "install esrally arch=$ARCH -> $RALLY_HOME"

  # Python 3 + venv
  if ! command -v python3 >/dev/null 2>&1; then
    yum install -y -q python3 python3-devel gcc gcc-c++ >/dev/null 2>&1 || \
    apt-get install -y -qq python3 python3-dev build-essential >/dev/null 2>&1
  fi

  PY="$(pick_python)" || {
    echo "ERROR: 找不到 Python >= 3.9（esrally 2.12.0 的硬要求）" >&2
    echo "       系统 python3 版本：$(python3 -V 2>&1)" >&2
    exit 1
  }
  log "使用 Python：$("$PY" -V 2>&1)"
  ensure_build_env "$PY"

  "$PY" -m venv "$RALLY_HOME"
  # shellcheck disable=SC1091
  source "$RALLY_HOME/bin/activate"
  # 国内直连 PyPI 经常超时；默认走阿里云镜像，可用 PIP_INDEX_URL 覆盖
  PIP_INDEX="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
  PIP_HOST="$(echo "$PIP_INDEX" | sed -E 's#https?://([^/]+)/.*#\1#')"
  export PIP_INDEX_URL="$PIP_INDEX"
  export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-$PIP_HOST}"
  log "pip 源：$PIP_INDEX_URL"
  pip install -q --upgrade pip wheel setuptools
  pip install -q esrally==2.12.0

  # 可选：换用内部源码分支（项目约定路径 ~/github/rally）
  if [ -n "$RALLY_PKG_URL" ]; then
    log "install rally from $RALLY_PKG_URL"
    pip install -q "$RALLY_PKG_URL"
  fi

  mkdir -p /data/rally/{benchmarks,tracks,results,corpus,logs}

  # esrally 的配置与语料默认落在 ~/.rally（在系统盘上，几个 GB 语料会把盘撑满）。
  # 直接把它做成指向数据盘的符号链接 —— 比手写 rally.ini 可靠，
  # 因为 rally.ini 的 config.version 与各 section 会随版本变化，手写容易失配。
  if [ -e "$HOME/.rally" ] && [ ! -L "$HOME/.rally" ]; then
    mv "$HOME/.rally" "$HOME/.rally.bak.$(date +%s)" 2>/dev/null || true
  fi
  ln -sfn /data/rally "$HOME/.rally"
  log "rally home -> /data/rally (symlink)"

  "$RALLY_HOME/bin/esrally" --version || { echo "rally install failed" >&2; exit 1; }
  log "esrally installed: $("$RALLY_HOME/bin/esrally" --version 2>&1 | head -1)"

  [ -n "$CORPUS_PKG" ] && install_corpus "$CORPUS_PKG"
}

# ---------- 语料烘焙 ----------
# 语料必须离线预置：track 定义默认走 github、语料走 Google Cloud Storage，
# 国内 ECS 两条路都拉不到，esrally race 会直接失败或长时间卡在下载。
#
# 开到 /opt/rally-corpus 而**不是** /data：运行期 userdata 会把数据盘挂到 /data，
# 挂载会遮住镜像里烘焙在 /data 下的内容。开机时再由 userdata 复制到数据盘。
install_corpus() {
  local pkg="$1"
  [ -f "$pkg" ] || { echo "ERROR: 语料包不存在：$pkg" >&2; exit 1; }

  log "烘焙语料 $(basename "$pkg") -> /opt/rally-corpus"
  rm -rf /opt/rally-corpus
  mkdir -p /opt/rally-corpus
  tar xzf "$pkg" -C /opt/rally-corpus

  # 校验清单里每一条；任一不符即失败 —— 宁可构建失败，也不要一个语料损坏的镜像
  if [ -f /opt/rally-corpus/benchmarks/MANIFEST.sha256 ]; then
    ( cd /opt/rally-corpus && sha256sum -c benchmarks/MANIFEST.sha256 ) \
      | tail -3 || { echo "ERROR: 语料 sha256 校验失败" >&2; exit 1; }
    log "语料 sha256 校验通过"
  else
    echo "WARN: 语料包内无 MANIFEST.sha256，跳过校验" >&2
  fi

  du -sh /opt/rally-corpus
  log "语料内容："
  find /opt/rally-corpus/benchmarks/tracks -maxdepth 2 -type d | sed 's/^/    track: /'
  find /opt/rally-corpus/benchmarks/data -maxdepth 2 -type f | sed 's/^/    data:  /'
}

install_common
case "$ROLE" in
  es)    install_es;;
  rally) install_rally;;
  *)     echo "--role must be es or rally" >&2; exit 1;;
esac

log "done"
