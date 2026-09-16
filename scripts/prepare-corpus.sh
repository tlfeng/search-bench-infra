#!/bin/bash
# 在本机准备 esrally 语料离线包，供镜像烘焙使用。
#
# 为什么必须离线打包（这是国内跑 esrally 最容易踩的坑）：
#   1. track 定义默认从 github.com/elastic/rally-tracks 拉 —— 国内经常拉不动；
#   2. 语料 base-url 是 https://rally-tracks.elastic.co，实测该域名由
#      Google Cloud Storage 托管（响应头带 x-guploader-uploadid），国内基本不可达。
#   两者任一失败，压测根本起不来。所以把 track + 语料打成 tar.gz，
#   构建镜像时 scp 进去烘焙，运行期 esrally 完全不碰外网。
#
# 用法：
#   ./scripts/prepare-corpus.sh                          # 默认 geonames
#   ./scripts/prepare-corpus.sh --track geonames --out corpus
#   ./scripts/prepare-corpus.sh --track-src /path/to/tracks          # 从本地目录复制 track 定义
#   ./scripts/prepare-corpus.sh --ssh-host root@<host> --ssh-key ~/.ssh/<key>   # 从已有环境取
#
# 只要本地 <out>/<track>/track.json 已存在就会直接复用，不会碰网络也不会碰 ssh。
#
# 产物：<out>/<track>-corpus.tar.gz  +  <out>/<track>-corpus.tar.gz.sha256
# 包内结构（可直接解到 ~/.rally 下）：
#   benchmarks/tracks/<track>/...
#   benchmarks/data/<corpus-name>/...
set -euo pipefail

# macOS 的 bsdtar 默认会带上 AppleDouble(._*) 与扩展属性，
# 结果语料包里混进一堆 ._xxx 垃圾文件（还会进 sha256 清单）。直接禁掉。
export COPYFILE_DISABLE=1

TRACK="geonames"
OUT="corpus"
TRACK_SRC=""          # 空=自动（本地已暂存的 track 优先；否则走 --ssh-host 取）
# 三个 ssh 相关参数都不设默认值：从已有环境取 track 定义属于「你有这个环境才用得上」的路径，
# 写死主机/私钥/目录既不可移植也容易泄露内部信息。只支持命令行或环境变量传入。
RALLY_SRC_DIR="${CORPUS_SSH_DIR:-}"
SSH_HOST="${CORPUS_SSH_HOST:-}"
SSH_KEY="${CORPUS_SSH_KEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --track)      TRACK="$2"; shift 2;;
    --out)        OUT="$2"; shift 2;;
    --track-src)  TRACK_SRC="$2"; shift 2;;
    --ssh-host)   SSH_HOST="$2"; shift 2;;
    --ssh-key)    SSH_KEY="$2"; shift 2;;
    --ssh-dir)    RALLY_SRC_DIR="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/$OUT"
STAGE="$OUT_DIR/stage/$TRACK"
TRACK_DEST="$STAGE/benchmarks/tracks/$TRACK"
DATA_DEST="$STAGE/benchmarks/data/$TRACK"

log() { echo "  [corpus] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

echo "=== 准备 $TRACK 语料离线包 ==="

# ---------- 1. track 定义 ----------
mkdir -p "$TRACK_DEST"
# 本地已暂存过就直接复用
if [ -f "$ROOT/corpus/$TRACK/track.json" ]; then
  log "复用本地已暂存的 track 定义"
  rsync -a --exclude '__pycache__' "$ROOT/corpus/$TRACK/" "$TRACK_DEST/"
elif [ -n "$TRACK_SRC" ] && [ -d "$TRACK_SRC" ]; then
  log "从 $TRACK_SRC 复制 track 定义"
  rsync -a --exclude '__pycache__' "$TRACK_SRC/" "$TRACK_DEST/"
else
  # 从已有环境取（track 定义很小，且能保证与历史基线同版本）
  [ -n "$SSH_HOST" ] || die "本地没有 corpus/$TRACK/track.json，也没指定来源。请用 --track-src <目录>，或 --ssh-host <user@host>（可选 --ssh-key）
         注意 track 定义一旦取回，建议顺手把它提交进 corpus/$TRACK/，以后就不再依赖远端"
  [ -n "$RALLY_SRC_DIR" ] || die "用 ssh 取 track 时还要给 --ssh-dir <远端存放 tracks 的目录>"
  log "从 $SSH_HOST 的 $RALLY_SRC_DIR/$TRACK 取 track 定义"
  SSH_OPTS=(-o StrictHostKeyChecking=no)
  if [ -n "$SSH_KEY" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" \
      "cd '$RALLY_SRC_DIR' && tar czf - $TRACK --exclude=__pycache__" \
      | tar xzf - -C "$STAGE/benchmarks/tracks/"
fi

[ -f "$TRACK_DEST/track.json" ] || die "track 定义不完整：缺 $TRACK_DEST/track.json"
log "track 定义就绪：$(find "$TRACK_DEST" -type f | wc -l | tr -d ' ') 个文件"

# ---------- 2. 解析语料清单 ----------
# track.json 是 Jinja2 模板，不能直接 json.load。这里只做启发式提取：
# 取 documents 数组里的 source-file / base-url，够用且不引入 Jinja 依赖。
CORPUS_NAME=$(/usr/bin/env python3 - "$TRACK_DEST/track.json" <<'PY'
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
# corpora 段里第一个 "name": "xxx" 通常是语料名
seg = t.split('"corpora"', 1)[-1]
m = re.search(r'"name"\s*:\s*"([^"]+)"', seg)
print(m.group(1) if m else "geonames")
PY
)
BASE_URL=$(/usr/bin/env python3 - "$TRACK_DEST/track.json" <<'PY'
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'"base-url"\s*:\s*"([^"]+)"', t)
print(m.group(1) if m else "")
PY
)
# 注意：macOS 自带 bash 3.2 没有 mapfile，用 while read 收集
FILES=()
while IFS= read -r _f; do
  [ -n "$_f" ] && FILES+=("$_f")
done < <(/usr/bin/env python3 - "$TRACK_DEST/track.json" <<'PY'
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
for m in re.finditer(r'"source-file"\s*:\s*"([^"]+)"', t):
    print(m.group(1))
PY
)

log "语料名=$CORPUS_NAME  base-url=$BASE_URL"
[ "${#FILES[@]}" -gt 0 ] || die "从 track.json 里没解析出 source-file"

mkdir -p "$DATA_DEST"
for f in "${FILES[@]}"; do
  dest="$DATA_DEST/$f"
  if [ -f "$dest" ]; then
    log "已存在，跳过：$f ($(du -h "$dest" | cut -f1))"
    continue
  fi
  # 本地暂存目录优先（避免重复下载 253MB）
  for cand in "$ROOT/corpus/$TRACK-data/$f" "$ROOT/corpus/$CORPUS_NAME-data/$f"; do
    if [ -f "$cand" ]; then
      log "复用本地暂存：$cand"
      cp "$cand" "$dest"
      break
    fi
  done
  [ -f "$dest" ] && continue
  [ -n "$BASE_URL" ] || die "$f 本地不存在且 track.json 无 base-url，无法下载"
  log "下载 $BASE_URL/$f （入方向流量通常免费，但国内到 GCS 可能慢/不通）"
  curl -fL --progress-bar --max-time 1800 "$BASE_URL/$f" -o "$dest.part" \
    || die "下载失败：$BASE_URL/${f}。可先手动下载后放到 $DATA_DEST/"
  mv "$dest.part" "$dest"
done
log "语料就绪：$(du -sh "$DATA_DEST" | cut -f1)"

# ---------- 3. 生成清单并打包 ----------
MANIFEST="$STAGE/benchmarks/MANIFEST.sha256"
( cd "$STAGE" && find benchmarks -type f ! -name 'MANIFEST.sha256' ! -name '._*' -print0 \
    | xargs -0 shasum -a 256 ) > "$MANIFEST"
log "已生成 sha256 清单：$(wc -l < "$MANIFEST" | tr -d ' ') 条"

PKG="$OUT_DIR/$TRACK-corpus.tar.gz"
tar czf "$PKG" -C "$STAGE" --exclude="._*" --exclude=".DS_Store" benchmarks
shasum -a 256 "$PKG" | awk '{print $1}' > "$PKG.sha256"

echo
echo "=== 完成 ==="
echo "  包:     $PKG  ($(du -h "$PKG" | cut -f1))"
echo "  sha256: $(cat "$PKG.sha256")"
echo
echo "下一步（二选一）："
echo "  A) 烘焙进镜像（推荐，运行期零外网）："
echo "       make image-rally PROFILE=<档位> WITH_CORPUS=1"
echo "  B) 开机时从 OSS 拉：把包上传到 OSS，并在 tfvars 里设 corpus_url"
