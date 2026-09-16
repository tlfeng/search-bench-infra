#!/bin/bash
# 镜像台账查询与切换：make image-ls / make image-use
#
# 台账 image-ids.txt（本地文件，不入库）由 build-image.sh 每次构建成功后追加，
# 格式为 TSV：日期\t角色\t架构\t引擎\t版本\t镜像ID\t镜像名。
# 本脚本只读台账、只改 tfvars，不调用任何云 API。
#
# 用法：
#   scripts/image.sh ls                              # 列出台账，标注 tfvars 当前指向
#   scripts/image.sh use --engine ez --arch x86      # 切 ES 镜像（改 tfvars 镜像 ID + engine）
#   scripts/image.sh use --role rally --arch arm     # 切 rally 镜像
#   scripts/image.sh use --id m-xxx                  # 按镜像 ID 切（其余字段从台账反查）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(dirname "$HERE")"
LEDGER="${LEDGER:-$ROOT/image-ids.txt}"
TFVARS="${TFVARS:-$ROOT/terraform/terraform.tfvars}"
# 镜像命名规则唯一事实来源（与 build-image.sh 共用）
# shellcheck disable=SC1091
. "$HERE/image-name.sh"

SUB="${1:-ls}"; [ $# -gt 0 ] && shift

norm_engine() { case "$1" in es|elasticsearch) echo elasticsearch ;; ez|easysearch) echo easysearch ;; *) echo "$1" ;; esac; }
norm_arch()   { case "$1" in x86|x86_64|amd64) echo x86 ;; arm|arm64|aarch64) echo arm ;; *) echo "$1" ;; esac; }

rows() {
  # 只输出合法 TSV 行（旧格式的自由文本行会被自动忽略）
  awk -F'\t' 'NF == 7 && $6 ~ /^m-/ { print }' "$LEDGER" 2>/dev/null || true
}

set_var() { # file key value —— tfvars 的 key="value" 行替换；key 不存在时返回 1
  local f=$1 k=$2 v=$3
  if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    sed -i.bak -E "s/^([[:space:]]*${k}[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${v}\"/" "$f"
    rm -f "$f.bak"
    return 0
  fi
  return 1
}

cmd_ls() {
  [ -f "$LEDGER" ] || { echo "台账不存在：${LEDGER}（构建一次镜像后自动生成）" >&2; exit 1; }
  printf '%-19s %-6s %-8s %-14s %-13s %-24s %s\n' "日期" "角色" "架构" "引擎" "版本" "镜像ID" "tfvars当前指向"
  local d r a e v i n var
  while IFS=$'\t' read -r d r a e v i n; do
    # 末尾 || true：pipefail 下 grep 无匹配会让整条管道返回 1，set -e 会中断脚本
    var=$(grep -E "\"$i\"" "$TFVARS" 2>/dev/null | head -1 | sed -E 's/^([A-Za-z_0-9]+).*/\1/' || true)
    if [ -z "$var" ]; then var="-"; fi
    printf '%-19s %-6s %-8s %-14s %-13s %-24s %s\n' "$d" "$r" "$a" "$e" "$v" "$i" "$var"
  done < <(rows)
}

cmd_use() {
  local ROLE_T="es" ENGINE_T="" ARCH_T="" ID=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) ROLE_T="$2"; shift 2;;
      --engine) ENGINE_T="$2"; shift 2;;
      --arch) ARCH_T="$2"; shift 2;;
      --id) ID="$2"; shift 2;;
      *) echo "unknown arg: $1" >&2; exit 1;;
    esac
  done
  [ -f "$TFVARS" ] || { echo "ERROR: $TFVARS 不存在（先 make setup 生成）" >&2; exit 1; }
  [ -f "$LEDGER" ] || { echo "ERROR: 台账不存在：${LEDGER}（先构建一次镜像）" >&2; exit 1; }

  local ROW ENGINE_N ARCH_N
  if [ -n "$ID" ]; then
    ROW=$(rows | grep -F "$ID" | tail -1)
    [ -n "$ROW" ] || { echo "ERROR: 台账里没有 $ID" >&2; exit 1; }
  else
    [ -n "$ARCH_T" ] || { echo "ERROR: 需要 --arch x86|arm（或 --id m-xxx）" >&2; exit 1; }
    ARCH_N=$(norm_arch "$ARCH_T")
    # 台账里存的是原始架构名（x86_64 / aarch64），两种写法都要能匹配
    local RAW="x86_64"
    [ "$ARCH_N" = "arm" ] && RAW="aarch64"
    local ROLE_N; ROLE_N=$(echo "$ROLE_T" | tr '[:upper:]' '[:lower:]')
    if [ "$ROLE_N" = "rally" ]; then
      ROW=$(rows | awk -F'\t' -v r="rally" -v a="$ARCH_N" -v raw="$RAW" '$2 == r && ($3 == a || $3 == raw)' | tail -1)
    else
      [ -n "$ENGINE_T" ] || { echo "ERROR: 需要 --engine es|ez（或 --role rally / --id m-xxx）" >&2; exit 1; }
      ENGINE_N=$(norm_engine "$ENGINE_T")
      ROW=$(rows | awk -F'\t' -v a="$ARCH_N" -v raw="$RAW" -v e="$ENGINE_N" '$2 == "es" && ($3 == a || $3 == raw) && $4 == e' | tail -1)
    fi
    [ -n "$ROW" ] || { echo "ERROR: 台账里没有匹配的镜像（role=$ROLE_N arch=${ARCH_N}${ENGINE_N:+ engine=$ENGINE_N}），先构建" >&2; exit 1; }
    ID=$(echo "$ROW" | cut -f6)
  fi

  # 从台账反查字段（--id 方式进来时也统一走这里）
  local R A E V
  R=$(echo "$ROW" | cut -f2); A=$(echo "$ROW" | cut -f3); E=$(echo "$ROW" | cut -f4); V=$(echo "$ROW" | cut -f5)
  ARCH_N=$(norm_arch "$A")
  local VAR
  if [ "$R" = "es" ]; then VAR="es_image_id_${ARCH_N}"; else VAR="rally_image_id_${ARCH_N}"; fi

  set_var "$TFVARS" "$VAR" "$ID"

  echo "  ✅ $VAR = \"$ID\"  （镜像名: $(echo "$ROW" | cut -f7), 引擎: $E, 版本: ${V}）"
  if [ "$R" = "es" ]; then
    # ES 镜像与 engine 配置必须成对切换，否则会把 easysearch 的密码配置
    # 打到 elasticsearch 二进制上（或反过来），到压测 401 才暴露。
    if [ -n "$ENGINE_T" ] || [ "$E" != "-" ]; then
      ENGINE_N=$(norm_engine "${ENGINE_T:-$E}")
      if set_var "$TFVARS" engine "$ENGINE_N"; then
        echo "  ✅ engine = \"$ENGINE_N\""
      else
        echo "  ℹ️  tfvars 无 engine 行未写入；Makefile 的 ENGINE 变量总会覆盖它，无影响"
      fi
      if [ "$ENGINE_N" = "easysearch" ] && grep -qE '^es_password[[:space:]]*=[[:space:]]*"Qwer@123"' "$TFVARS"; then
        echo "  ⚠️  easysearch 密码策略要求 >=9 位：make up 请带 ENGINE=easysearch（自动用 Qwer@1234）"
      fi
    fi
    echo "  下一步：make up PROFILE=... ENGINE=${ENGINE_N:-elasticsearch}"
  else
    echo "  下一步：make up PROFILE=..."
  fi
}

cmd_fix_names() {
  [ -f "$LEDGER" ] || { echo "ERROR: 台账不存在：${LEDGER}（先构建一次镜像）" >&2; exit 1; }
  local REGION_R="${REGION:-cn-hangzhou}"
  local PREFIX_T="${IMAGE_NAME_PREFIX:-esbench}"
  local changed=0 kept=0
  local d r a e v i n canon cur
  while IFS=$'\t' read -r d r a e v i n; do
    # 版本列缺省（旧台账行）时：rally 按 install.sh 默认版本补，es 按引擎默认占位
    if [ "$v" = "-" ]; then
      if [ "$r" = "rally" ]; then v="2.12.0"; else v="default"; fi
    fi
    canon=$(compose_image_name "$PREFIX_T" "$r" "$e" "$v" "$a" "")
    if [ "$canon" = "$n" ]; then
      echo "  KEEP ${i}：${n}（台账名已是规范名）"
      kept=$((kept + 1))
      continue
    fi
    cur=$(aliyun ecs DescribeImages --RegionId "$REGION_R" --ImageId "$i" 2>/dev/null \
            | jq -r '.Images.Image[0].ImageName // empty')
    if [ -z "$cur" ]; then
      echo "  SKIP ${i}：云端查询不到，跳过"
      continue
    fi
    if [ "$cur" = "$canon" ] || case "$cur" in *"-$v"-* | *"-$v") true ;; *) false ;; esac; then
      echo "  KEEP ${i}：${cur}（名字里已含版本 ${v}，不再改）"
      kept=$((kept + 1))
      continue
    fi
    if aliyun ecs ModifyImageAttribute --RegionId "$REGION_R" --ImageId "$i" --ImageName "$canon" >/dev/null 2>&1; then
      echo "  ✅ ${i}：$cur -> $canon"
      awk -F'\t' -v id="$i" -v nm="$canon" 'BEGIN{OFS="\t"} $6 == id {$7 = nm} {print}' \
        "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
      changed=$((changed + 1))
    else
      echo "  ❌ $i 改名失败（目标名 ${canon}）"
    fi
  done < <(rows)
  echo "完成：改名 $changed 个，保留 $kept 个"
}

case "$SUB" in
  ls)        cmd_ls ;;
  use)       cmd_use "$@" ;;
  fix-names) cmd_fix_names ;;
  *) echo "用法: image.sh [ls | use --engine es|ez --arch x86|arm | use --id m-xxx | fix-names]" >&2; exit 1 ;;
esac
