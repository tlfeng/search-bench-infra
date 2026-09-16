#!/bin/bash
# 并行压测矩阵：按 stacks.yaml 同时跑多套独立环境，最后汇总成一张对照表。
#
# 每套 stack 的流水线：up -> bench -> fetch -> down。
# down 放在每套自己的流水线里，而不是等所有栈跑完再统一销毁 ——
# 哪一套先跑完就先释放它的计费资源，而不是让先完成的那套干等着。
#
# 三条硬约束（不是"尽量"，是必须）：
#   1) bench 失败也要 fetch：产物在实例数据盘上，实例一销毁就没了；
#   2) 任何一步失败都要 down：否则留下无人认领的实例在后台计费；
#   3) 并发前的库存预检只警告不阻断：它的目的是把"云上开不出来"提前说出来，
#      不是替你决定能不能跑。预检不确定时必须说"未知"，不能当成"无货"。
#
# 用法：
#   scripts/bench-matrix.sh                 # 用 ./stacks.yaml，交互确认后开跑
#   scripts/bench-matrix.sh --dry-run       # 只打印计划和预检，不开机器（0 费用）
#   scripts/bench-matrix.sh --yes           # 跳过确认（非交互场景必需）
#   scripts/bench-matrix.sh --stacks x,a    # 只跑指定的几个
#   scripts/bench-matrix.sh --parallel 1    # 退化成串行（做对照用）
#   scripts/bench-matrix.sh --no-down       # 保留实例便于登进去查问题
#   scripts/bench-matrix.sh --test-mode     # 极小数据集，只打通链路
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

FILE="$ROOT/stacks.yaml"
ONLY=""
DRY_RUN=0
ASSUME_YES=0
PAR=0                    # 0 = 不限（等于栈数）
DO_UP=1; DO_BENCH=1; DO_FETCH=1; DO_DOWN=1
TEST_MODE=0
SKIP_PREFLIGHT=0

# 允许的键白名单。它同时承担两个职责：
#   1) 键名拼错立刻报错，而不是静默用默认值跑（静默是这类脚本最贵的失败模式）；
#   2) 让下面用 eval 拼变量名是安全的 —— 键名不可能带进 shell 元字符。
ALLOWED_KEYS=" name profile engine zone vpc_cidr vswitch_cidr track challenge clients codec rally_on use_spot spot_es spot_rally "

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2;;
    --stacks) ONLY="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --yes|-y) ASSUME_YES=1; shift;;
    --parallel) PAR="$2"; shift 2;;
    --no-up) DO_UP=0; shift;;
    --no-bench) DO_BENCH=0; shift;;
    --no-fetch) DO_FETCH=0; shift;;
    --no-down|--keep) DO_DOWN=0; shift;;
    --test-mode) TEST_MODE=1; shift;;
    --no-preflight) SKIP_PREFLIGHT=1; shift;;
    # help 取自文件头的注释块。不能用 sed -n '2,25p' 这种硬编码行号：
    # 注释一改长就会把 set -euo pipefail、HERE=... 这些源码一起打印出来（实测踩过）。
    # 这里改成"打印开头连续的 # 行，跳过空行，遇到第一行真代码就停"。
    -h|--help) awk 'NR>1{ if ($0 ~ /^#/) { sub(/^# ?/, ""); print; next }
                     if ($0 ~ /^[[:space:]]*$/) next; exit }' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[ -f "$FILE" ] || { echo "ERROR: 找不到矩阵定义文件 $FILE" >&2; exit 1; }
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "  ⚠️  $*" >&2; }

# make matrix 一定会从这里继承到一个 STACK（没写也会被导出成 default）。
# 但矩阵"跑哪几套"由 --stacks 决定，STACK 在这里没有任何作用——
# 它不会影响读哪个档位、查哪个库存，却会让人误以为"只跑这一套"。
# 与其让一个无效参数安静地通过，不如直接拒绝并指路。
if [ "${STACK:-default}" != "default" ]; then
  # ${STACK} 必须带花括号：后面紧跟全角句号，bash 3.2 会把多字节字节并进变量名
  die "make matrix 不接受 STACK=${STACK}。要只跑部分栈请用 --stacks <名>；STACK 是给单栈命令（up/bench/fetch/down）用的"
fi

# ============================================================================
# 1. 解析 stacks.yaml
# ============================================================================
# 只实现本 schema 需要的那个最小 YAML 子集：defaults 平表 + stacks 平表列表。
# 遇到嵌套、行内集合一律报错 —— 宁可拒绝执行，也不要"猜一个解释"。
# 猜错的代价是你拿着一份自己没写过的配置去开机器。
parse_yaml() {
  awk '
    function err(m) { printf "ERROR: %s 第 %d 行：%s\n", FILENAME, NR, m > "/dev/stderr"; bad = 1 }
    {
      line = $0
      # 去注释：只有 # 出现在行首或空白之后才算注释，避免砍掉值里的 #
      if (match(line, /(^|[ \t])#/)) line = substr(line, 1, RSTART - 1)
      gsub(/^[ \t]+/, "", line); gsub(/[ \t]+$/, "", line)
      if (line == "") next

      match($0, /^[ ]*/); indent = RLENGTH
      if (indent == 0) {
        if (line !~ /:$/) { err("顶层只能是 section:（defaults / stacks）"); next }
        sect = substr(line, 1, length(line) - 1)
        if (sect != "defaults" && sect != "stacks") { err("不认识的 section: " sect); next }
        next
      }
      if (sect == "") { err("缩进行出现在任何 section 之前"); next }

      body = line
      is_new = 0
      if (substr(body, 1, 2) == "- ") { is_new = 1; body = substr(body, 3) }

      p = index(body, ":")
      if (p == 0) { err("不是 key: value 形式：" body); next }
      k = substr(body, 1, p - 1); v = substr(body, p + 1)
      gsub(/^[ \t]+/, "", k); gsub(/[ \t]+$/, "", k)
      gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
      if (k == "") { err("键名为空"); next }
      if (v == "") { err("键 " k " 的值为空"); next }
      # 按首字符判断，不用正则里的字符类 —— "[\[\{]" 这种写法在 BWK awk 下
      # 是否把 [ 算进集合是不确定的，靠它会静默放过行内列表。
      fc = substr(v, 1, 1)
      if (fc == "[" || fc == "{") { err("不支持行内列表/映射：" k " = " v); next }

      if (sect == "defaults") {
        if (is_new) { err("defaults 下不应出现列表项（- ）"); next }
        print "default\t-\t" k "\t" v
      } else {
        if (is_new) item++
        if (item == 0) { err("stacks 下必须以 \"- name: xxx\" 开头"); next }
        print "stack\t" item "\t" k "\t" v
      }
    }
    END { if (bad) exit 1 }
  ' "$1"
}

strip_quotes() {
  local v="$1" DQ='"' SQ="'"
  v="${v#$DQ}"; v="${v%$DQ}"
  v="${v#$SQ}"; v="${v%$SQ}"
  printf '%s' "$v"
}

N=0
# 动态变量名走 eval —— macOS 自带的 bash 3.2 没有关联数组。
# 安全性由 ALLOWED_KEYS 白名单保证（键名已校验，不可能含 shell 元字符）。
# 解析器的输出先整体收下再校验退出码：走进程替换 < <(...) 时它的失败是读不到的，
# 那会让"解析失败"退化成"静默按空配置跑"。
if ! PARSED="$(parse_yaml "$FILE")"; then
  die "stacks.yaml 解析失败（具体行号见上方 ERROR）"
fi

while IFS=$'\t' read -r kind idx key val; do
  [ -n "$kind" ] || continue
  case "$ALLOWED_KEYS" in
    *" $key "*) ;;
    *) die "stacks.yaml 不认识的键：'$key'（允许：$(echo "$ALLOWED_KEYS" | tr -s ' ' ' ')）" ;;
  esac
  val="$(strip_quotes "$val")"
  if [ "$kind" = "default" ]; then
    eval "DEF_${key}=\$val"
  else
    case "$idx" in ''|*[!0-9]*) die "内部错误：非法的栈序号 '$idx'";; esac
    eval "S_${key}_${idx}=\$val"
    [ "$idx" -gt "$N" ] && N="$idx"
  fi
done <<<"$PARSED"

[ "$N" -gt 0 ] || die "$FILE 里没有解析出任何 stack"

# 生效值：栈内覆盖优先，否则回落 defaults
eff() { # $1=栈序号 $2=键
  local v=""
  eval "v=\${S_${2}_${1}:-}"
  [ -n "$v" ] || eval "v=\${DEF_${2}:-}"
  printf '%s' "$v"
}

# 节点数规则与 Makefile 保持一致（那边是唯一事实来源，这里只用于估算与预检）
nodes_for_profile() {
  case "$1" in debug|arm-debug) echo 1 ;; *) echo 2 ;; esac
}

# ---- 选栈 ----
SEL=""
if [ -n "$ONLY" ]; then
  for want in $(echo "$ONLY" | tr ',' ' '); do
    hit=0
    i=1
    while [ "$i" -le "$N" ]; do
      nm="$(eff "$i" name)"
      if [ "$nm" = "$want" ]; then SEL="$SEL $i"; hit=1; break; fi
      i=$((i + 1))
    done
    [ "$hit" = 1 ] || die "--stacks 里的 '$want' 在 $FILE 中不存在"
  done
else
  i=1
  while [ "$i" -le "$N" ]; do SEL="$SEL $i"; i=$((i + 1)); done
fi
[ -n "$SEL" ] || die "没有选中任何 stack"
set -- $SEL; NSEL=$#
SEL="$*"

# --parallel 要显式校验，不能用 `[ "$PAR" -eq 0 ] || PAR=0` 兜底：
# 后者会把 `--parallel abc` 静默当成 0（= 不限并发），与用户意图相反且毫无提示。
case "$PAR" in
  ''|*[!0-9]*) die "--parallel 需要一个非负整数，收到 '$PAR'" ;;
esac
if [ "$PAR" = 0 ]; then PAR="$NSEL"; fi

# 栈名校验必须覆盖**全部**栈，而不是只校验选中的：
#   - 字符集不合法 → 名字会进资源名 / workspace 名 / OSS 路径，也会被 stacks.sh 用来反推归属
#   - 重名 → 两套环境写同一个 .log 与 .rc 文件，且 make down STACK=<名> 语义不明
# 这两种错在 --stacks 只选了别的栈时会被完全掩盖，等真跑到那个栈才炸。
# 规则与 terraform variables.tf 里 stack 的 validation 保持同一套（那边是唯一事实来源）。
SEEN_NAME=" "
i=1
while [ "$i" -le "$N" ]; do
  nm="$(eff "$i" name)"
  [ -n "$nm" ] || die "栈 #$i 缺少 name"
  if ! printf '%s' "$nm" | grep -qE '^[a-z0-9][a-z0-9-]{0,15}$'; then
    die "栈名 '$nm' 不合法：只能是小写字母/数字开头，后接小写字母/数字/短横线，最长 16 位（与 terraform 的 stack 校验一致）"
  fi
  # 与 terraform 的 reserved-name 校验对齐（^(es|rally)(-|$)）：espresso / rally2 合法，
  # es / es-1 / rally 不合法 —— 资源名里这两个词已表示角色，stacks.sh 靠名字反推归属会歧义。
  case "$nm" in
    es|es-*|rally|rally-*) die "栈名 '$nm' 不能是 es / rally 或以它们加短横线开头：资源名里这两个词已表示角色，会造成归属歧义" ;;
  esac
  case "$SEEN_NAME" in
    *" $nm "*) die "栈名重复：'$nm'。同名会让两套环境写同一个日志与 .rc 文件，且 make down STACK=$nm 语义不明" ;;
  esac
  SEEN_NAME="$SEEN_NAME$nm "
  i=$((i + 1))
done

for i in $SEL; do
  [ -n "$(eff "$i" profile)" ] || die "栈 $(eff "$i" name) 缺少 profile（必填）"
done

# ============================================================================
# 2. terraform 侧的事实（档位 -> 机型）与云侧库存
# ============================================================================
REGION="$(sed -nE 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"(.*)".*/\1/p' \
          "$ROOT/terraform/terraform.tfvars" 2>/dev/null | head -1)"
REGION="${REGION:-cn-hangzhou}"

# 读 terraform 侧「纯配置」事实（档位 -> 机型）。
#
# 用 console 而不是 plan+show：console 只求值表达式，**不会触发资源上的 precondition**
# （precondition 要到 plan/apply 才检查）。这一点很关键 ——
# tfvars 里通常只配了一个架构的镜像 ID（另一个架构留空），另一架构的档位根本 plan 不出来，
# 走 plan 的写法会在这种机器上静默降级成"跳过预检"，而 console 照样读得到档位表。
#
# 强制 STACK=default：这是"配置"而非"环境状态"，与调用者当前在哪套栈无关。
tf_console_json() { # $1 = HCL 表达式，须求值成一个 JSON 字符串
  local out
  out="$(printf 'jsonencode(%s)\n' "$1" \
         | STACK=default "$HERE/tf.sh" console 2>/dev/null \
         | grep -m1 '"' | jq -r . 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

ALIYUN="$(command -v aliyun || true)"
if [ -z "$ALIYUN" ]; then
  for c in /opt/homebrew/bin/aliyun "$HOME/.local/bin/aliyun"; do
    if [ -x "$c" ]; then ALIYUN="$c"; break; fi
  done
fi

# 一次 console 调用同时拿到两个目录（比调两次 terraform 快一半）
CATALOG=""
if CATALOG="$(tf_console_json '{profiles = local.es_by_profile, rally = local.rally_by_key}')"; then
  :
else
  warn "读不到档位目录（terraform console 求值失败），跳过规格解析与库存预检"
  CATALOG=""
fi

cat_type() { # $1=profile -> ES 机型
  [ -n "$CATALOG" ] || return 1
  printf '%s' "$CATALOG" | jq -r --arg p "$1" '.profiles[$p].type // empty'
}
cat_size() { # $1=profile -> 规格档（debug/cheap/main）
  [ -n "$CATALOG" ] || return 1
  printf '%s' "$CATALOG" | jq -r --arg p "$1" '.profiles[$p].size // empty'
}
rally_type() { # $1=rally_on(arm|x86) $2=规格档
  [ -n "$CATALOG" ] || return 1
  printf '%s' "$CATALOG" | jq -r --arg k "$1-$2" '.rally[$k].type // empty'
}

# 查某机型在 region 内哪些可用区有货（1 次调用；不带 ZoneId 让服务端返回全部有货区）。
# 必须区分"确实无货"与"查询失败"：前者可以据此让用户改 zone，
# 后者如果被当成无货，就会对每一个栈都喷一个假警报 —— 假警报比不报更糟。
stock_zones() {
  [ -n "$ALIYUN" ] || return 1
  local out
  out="$("$ALIYUN" ecs DescribeAvailableResource --RegionId "$REGION" \
          --DestinationResource InstanceType --InstanceType "$1" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -e '.AvailableZones' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -r --arg t "$1" '
    [ .AvailableZones.AvailableZone[]?
      | select(any(.AvailableResources.AvailableResource[]?.SupportedResources.SupportedResource[]?;
                   .StatusCategory == "WithStock" and .Value == $t))
      | .ZoneId ] | unique | join(" ")'
}

var_safe() { printf '%s' "$1" | tr '.-' '__'; }

# 1/true/yes/on -> 1，0/false/no/off -> 0，其它/空 -> 空（表示"未指定，回落上一层"）。
# 与 Makefile 的 asbool 同一套语义：不归一化就会出现 `SPOT_ES=True` 被判成相反结果。
asbool() {
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    1|true|yes|on)  echo 1 ;;
    0|false|no|off) echo 0 ;;
    *)              echo "" ;;
  esac
}

# ============================================================================
# 3. 打印计划
# ============================================================================
TS="$(date +%Y%m%d-%H%M%S)"
MATRIX_DIR="$ROOT/results/_matrix/$TS"
LOG_DIR="$MATRIX_DIR"

echo "=== 并行压测矩阵 ==="
echo "  定义文件 : $FILE"
echo "  栈数     : $NSEL   （并行上限 ${PAR}）"
echo "  地域     : $REGION"
echo -n "  步骤     :"
[ "$DO_UP" = 1 ]    && echo -n " up"
[ "$DO_BENCH" = 1 ] && echo -n " bench"
[ "$DO_FETCH" = 1 ] && echo -n " fetch"
if [ "$DO_DOWN" = 1 ]; then echo " down"; else echo " （保留实例，不销毁）"; fi
echo "  日志目录 : $MATRIX_DIR"
echo
printf '  %-6s %-12s %-14s %-15s %-18s %s\n' STACK PROFILE ENGINE ZONE 网段 节点数
tot_nodes=0
for i in $SEL; do
  nm="$(eff "$i" name)"; p="$(eff "$i" profile)"
  e="$(eff "$i" engine)"; [ -n "$e" ] || e="elasticsearch"
  z="$(eff "$i" zone)";   [ -n "$z" ] || z="(tfvars)"
  v="$(eff "$i" vpc_cidr)"; [ -n "$v" ] || v="(tfvars)"
  nd="$(nodes_for_profile "$p")"; tot_nodes=$((tot_nodes + nd))
  printf '  %-6s %-12s %-14s %-15s %-18s %s\n' "$nm" "$p" "$e" "$z" "$v" "$nd"
done
echo
echo "  合计 ES 节点 $tot_nodes 台，另加 $NSEL 台 rally。"
echo "  并发跑 $NSEL 套与串行跑 $NSEL 轮，总机时与总花费相同，省的只是墙钟时间。"
echo "  代价：同时占用 $NSEL 倍 vCPU 配额；任一套漏了 down 就同时在烧 N 倍的钱（用 make stacks 盯）。"
for i in $SEL; do
  case "$(eff "$i" profile)" in
    *-main)
      echo "  ⚠️  含 *-main 档（16 vCPU/节点），配额压力最大 —— 预检会给出具体余量。"
      break ;;
  esac
done

# ============================================================================
# 4. 预检：库存
# ============================================================================
if [ "$SKIP_PREFLIGHT" = 0 ]; then
  echo
  echo "=== 预检：目标可用区库存 ==="
  if [ -z "$CATALOG" ]; then
    warn "跳过（拿不到档位目录）"
  elif [ -z "$ALIYUN" ]; then
    warn "跳过（找不到 aliyun CLI）"
  elif ! . "$HERE/tf-env.sh"; then
    # 预检需要读库存 API，凭据缺失时降级为"跳过"，不要因此让整条矩阵跑不起来
    warn "跳过（无法加载阿里云凭据）"
  else
    TYPES=""
    for i in $SEL; do
      p="$(eff "$i" profile)"
      t="$(cat_type "$p")" || t=""
      [ -n "$t" ] && TYPES="$TYPES $t"
      ro="$(eff "$i" rally_on)"; [ -n "$ro" ] || ro="arm"
      rt="$(rally_type "$ro" "$(cat_size "$p")")" || rt=""
      [ -n "$rt" ] && TYPES="$TYPES $rt"
    done
    TYPES="$(echo "$TYPES" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

    for t in $TYPES; do
      if zs="$(stock_zones "$t")"; then
        eval "STOCK_$(var_safe "$t")=\"\$zs\""
        printf '  %-20s 有货可用区：%s\n' "$t" "${zs:-（本地域无货）}"
      else
        eval "STOCK_$(var_safe "$t")=__UNKNOWN__"
        printf '  %-20s 库存查询失败（跳过该机型判定）\n' "$t"
      fi
    done

    echo
    BLOCK=0
    for i in $SEL; do
      nm="$(eff "$i" name)"; p="$(eff "$i" profile)"; z="$(eff "$i" zone)"
      t="$(cat_type "$p")" || t=""
      if [ -z "$t" ]; then
        printf '  %-6s %-12s %s\n' "$nm" "$p" "（档位无法解析，跳过）"; continue
      fi
      if [ -z "$z" ]; then
        printf '  %-6s %-12s %-15s %s\n' "$nm" "$p" "(tfvars)" "按 terraform.tfvars 的 zone_id 走"
        continue
      fi
      eval "zs=\${STOCK_$(var_safe "$t"):-}"
      if [ "$zs" = "__UNKNOWN__" ]; then
        printf '  %-6s %-12s %-15s ⚠️  库存未知\n' "$nm" "$p" "$z"
        continue
      fi
      ok=0
      for cand in $zs; do [ "$cand" = "$z" ] && ok=1 && break; done
      if [ "$ok" = 1 ]; then
        printf '  %-6s %-12s %-15s ✅ 有货\n' "$nm" "$p" "$z"
      else
        first="$(echo "$zs" | awk '{print $1}')"
        printf '  %-6s %-12s %-15s ❌ 无货；建议改成 %s\n' "$nm" "$p" "$z" "${first:-（本地域都无货）}"
        BLOCK=1
      fi
    done
    if [ "$BLOCK" = 1 ]; then
      echo
      warn "有栈的目标可用区无货。并发时开一半才失败会留下半套资源在计费，建议先改 zone。"
      warn "这是警告不是阻断：库存随时会变，也可能是我查错了。要硬跑加 --no-preflight。"
    fi

    # ---- vCPU 配额 ----
    # 并行启动最容易"开一半失败"的地方。而且竞价与按量在阿里云是**两本独立账**
    # （max/used-postpaid-instance-vcpu-count 与 max/used-spot-instance-vcpu-count），
    # 只算总量会漏判。额度顶到时 CreateInstance 直接失败，在并发场景下就是
    # "第一套已经起来在计费、第二套死活起不来"。
    _n=1; _args=""
    for t in $TYPES; do _args="$_args --InstanceTypes.$_n $t"; _n=$((_n + 1)); done
    VCPU_MAP=""
    if [ -n "$_args" ]; then
      # shellcheck disable=SC2086
      VCPU_MAP="$("$ALIYUN" ecs DescribeInstanceTypes $_args 2>/dev/null \
                  | jq -c '[.InstanceTypes.InstanceType[] | {key: .InstanceTypeId, value: .CpuCoreCount}] | from_entries' \
                    2>/dev/null || true)"
    fi

    # stacks.yaml 没写 use_spot/spot_es/spot_rally 时，回落 tfvars 的 use_spot
    TV_SPOT="$(asbool "$(sed -nE 's/^[[:space:]]*use_spot[[:space:]]*=[[:space:]]*(true|false).*/\1/p' \
                "$ROOT/terraform/terraform.tfvars" 2>/dev/null | head -1)")"
    if [ -z "$TV_SPOT" ]; then TV_SPOT=0; fi

    if [ -z "$VCPU_MAP" ]; then
      printf '  vCPU 配额：查不到机型规格（跳过）\n'
    else
      need_post=0; need_spot=0; vcpu_known=1
      for i in $SEL; do
        p="$(eff "$i" profile)"; nd="$(nodes_for_profile "$p")"
        et="$(cat_type "$p")" || et=""
        ro="$(eff "$i" rally_on)"; [ -n "$ro" ] || ro="arm"
        rt="$(rally_type "$ro" "$(cat_size "$p")")" || rt=""
        ve="$(printf '%s' "$VCPU_MAP" | jq -r --arg k "$et" '.[$k] // 0')"
        vr="$(printf '%s' "$VCPU_MAP" | jq -r --arg k "$rt" '.[$k] // 0')"
        if [ "${ve:-0}" -le 0 ] || [ "${vr:-0}" -le 0 ]; then vcpu_known=0; fi

        # 计费方式优先级与 Makefile 的 SPOT_ES/SPOT_RALLY > USE_SPOT > tfvars 完全一致
        base="$TV_SPOT"
        u="$(asbool "$(eff "$i" use_spot)")"; if [ -n "$u" ]; then base="$u"; fi
        es_spot="$base"; se="$(asbool "$(eff "$i" spot_es)")";    if [ -n "$se" ]; then es_spot="$se"; fi
        rl_spot="$base"; sr="$(asbool "$(eff "$i" spot_rally)")"; if [ -n "$sr" ]; then rl_spot="$sr"; fi

        es_v=$((nd * ${ve:-0}))
        if [ "$es_spot" = 1 ]; then need_spot=$((need_spot + es_v)); else need_post=$((need_post + es_v)); fi
        if [ "$rl_spot" = 1 ]; then need_spot=$((need_spot + ${vr:-0})); else need_post=$((need_post + ${vr:-0})); fi
      done

      QUOTA="$("$ALIYUN" ecs DescribeAccountAttributes --RegionId "$REGION" 2>/dev/null || true)"
      qv() {
        printf '%s' "$QUOTA" | jq -r --arg n "$1" \
          '[.AccountAttributeItems.AccountAttributeItem[] | select(.AttributeName == $n)
            | .AttributeValues.ValueItem[].Value][0] // empty'
      }
      mp="$(qv max-postpaid-instance-vcpu-count)"; up="$(qv used-postpaid-instance-vcpu-count)"
      ms="$(qv max-spot-instance-vcpu-count)";     us="$(qv used-spot-instance-vcpu-count)"

      if [ -z "$mp" ] || [ -z "$ms" ]; then
        printf '  vCPU 配额：查询不到（跳过）\n'
      else
        rem_post=$((mp - ${up:-0})); rem_spot=$((ms - ${us:-0}))
        printf '  本次新增需求：按量 %d / 竞价 %d vCPU\n' "$need_post" "$need_spot"
        printf '  账户余量(%s)：按量 %d（上限 %s 已用 %s）；竞价 %d（上限 %s 已用 %s）\n' \
          "$REGION" "$rem_post" "$mp" "${up:-0}" "$rem_spot" "$ms" "${us:-0}"
        if [ "$need_post" -gt "$rem_post" ] || [ "$need_spot" -gt "$rem_spot" ]; then
          warn "vCPU 配额可能不足 —— 会开到一半失败并留下半套计费资源。"
          warn "先去控制台提配额，或拆成两批跑（--stacks x 然后 --stacks a）。"
        elif [ "$vcpu_known" = 1 ]; then
          printf '  ✅ 配额充足\n'
        fi
      fi
    fi
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "（--dry-run：到此为止，未创建任何资源，0 费用）"
  exit 0
fi

# ============================================================================
# 5. 确认
# ============================================================================
echo
if [ "$ASSUME_YES" != 1 ]; then
  if [ -t 0 ]; then
    printf '将并行创建 %d 套环境（每套独立 VPC + 实例，按量计费）。确认请输入 yes：' "$NSEL"
    read -r ans
    [ "$ans" = "yes" ] || { echo "已取消。"; exit 1; }
  else
    die "非交互环境下必须显式加 --yes（这条保护是为了避免误开多套计费资源）"
  fi
fi

mkdir -p "$MATRIX_DIR"

# 把解析后的配置原地留档。事后读报告时必须能确认"这一栈到底是什么配置"，
# 而不是靠回忆当时命令行敲了什么 —— 那正是对照实验最容易失去可复现性的地方。
{
  printf 'stack\tprofile\tengine\tzone\tvpc_cidr\tvswitch_cidr\ttrack\tchallenge\tclients\tcodec\trally_on\tuse_spot\tspot_es\tspot_rally\tnodes\n'
  for i in $SEL; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(eff "$i" name)" "$(eff "$i" profile)" "$(eff "$i" engine)" \
      "$(eff "$i" zone)" "$(eff "$i" vpc_cidr)" "$(eff "$i" vswitch_cidr)" \
      "$(eff "$i" track)" "$(eff "$i" challenge)" "$(eff "$i" clients)" \
      "$(eff "$i" codec)" "$(eff "$i" rally_on)" "$(eff "$i" use_spot)" \
      "$(eff "$i" spot_es)" "$(eff "$i" spot_rally)" \
      "$(nodes_for_profile "$(eff "$i" profile)")"
  done
} > "$MATRIX_DIR/plan.tsv"

# ============================================================================
# 6. 并行执行
# ============================================================================
# 每个 stack 一个子 shell，日志独立落文件；父进程只负责窗口控制与进度。
# 子 shell 里先 set +e：每一步的成败都要自己判断，不能让 errexit 把
# "fetch / down 这两个必须执行的收尾"跳过去。
run_stack() {
  local i="$1"
  local name; name="$(eff "$i" name)"
  local log="$LOG_DIR/$name.log"
  exec >>"$log" 2>&1
  set +e

  local prof eng zone vpc vsw track chal clients codec rally_on us se sr
  prof="$(eff "$i" profile)";        eng="$(eff "$i" engine)"
  zone="$(eff "$i" zone)";           vpc="$(eff "$i" vpc_cidr)"
  vsw="$(eff "$i" vswitch_cidr)";    track="$(eff "$i" track)"
  chal="$(eff "$i" challenge)";      clients="$(eff "$i" clients)"
  codec="$(eff "$i" codec)";         rally_on="$(eff "$i" rally_on)"
  us="$(eff "$i" use_spot)";         se="$(eff "$i" spot_es)"
  sr="$(eff "$i" spot_rally)"
  [ -n "$eng" ] || eng="elasticsearch"
  [ -n "$track" ] || track="geonames"
  [ -n "$chal" ] || chal="append-no-conflicts"
  [ -n "$codec" ] || codec="default"

  # esrally 的 user-tags 与 dist-version 判定都认 ez/es
  local eng_tag="es"
  case "$eng" in easysearch|ez) eng_tag="ez" ;; esac

  # 清掉从上层 make 继承来的 STACK / 路径变量。不清的话，嵌套 make 会带着
  # 上一个栈的 TF_DATA_DIR、LOCAL_DIR 进来，变成"在 A 的 state 上操作 B 的资源"，
  # 而这种事故几乎无法从日志里看出来。
  run_make() {
    ( cd "$ROOT" && env -u STACK -u TF_DATA_DIR -u LOCAL_DIR -u OSS_PREFIX \
        make --no-print-directory "$@" )
  }

  local upargs="" benchargs=""
  [ -n "$zone" ] && upargs="$upargs ZONE=$zone"
  [ -n "$vpc" ]  && upargs="$upargs VPC_CIDR=$vpc"
  [ -n "$vsw" ]  && upargs="$upargs VSWITCH_CIDR=$vsw"
  [ -n "$rally_on" ] && upargs="$upargs RALLY_ON=$rally_on"
  [ -n "$us" ] && upargs="$upargs USE_SPOT=$us"
  [ -n "$se" ] && upargs="$upargs SPOT_ES=$se"
  [ -n "$sr" ] && upargs="$upargs SPOT_RALLY=$sr"

  [ -n "$clients" ] && benchargs="$benchargs CLIENTS=$clients"
  benchargs="$benchargs CODEC=$codec ENGINE_NAME=$eng_tag"
  [ "$TEST_MODE" = 1 ] && benchargs="$benchargs TEST_MODE=1"

  local rc=0
  echo "================================================================"
  echo "[$name] 开始 $(date -Is)"
  echo "  profile=$prof engine=$eng zone=${zone:-tfvars} vpc=${vpc:-tfvars}"
  echo "  track=$track challenge=$chal clients=${clients:-默认} codec=$codec rally_on=${rally_on:-默认}"
  echo "================================================================"

  if [ "$DO_UP" = 1 ]; then
    echo "----- [$name] up $(date +%H:%M:%S)"
    # shellcheck disable=SC2086
    if ! run_make up STACK="$name" PROFILE="$prof" ENGINE="$eng" $upargs; then
      echo "!!!! [$name] up 失败（跳过 bench，仍然执行 fetch/down 收尾）"
      rc=1
    fi
  fi

  if [ "$rc" = 0 ] && [ "$DO_BENCH" = 1 ]; then
    echo "----- [$name] bench $(date +%H:%M:%S)"
    # PROFILE 必须一起传：run-bench 的 --tag arch 与 --expected-nodes 都由它派生
    # shellcheck disable=SC2086
    if ! run_make bench STACK="$name" PROFILE="$prof" TRACK="$track" CHALLENGE="$chal" $benchargs; then
      echo "!!!! [$name] bench 失败"
      rc=1
    fi
  fi

  # fetch / down 无论前面成败都要走完：产物在实例数据盘上，实例一销毁就没了。
  if [ "$DO_FETCH" = 1 ]; then
    echo "----- [$name] fetch $(date +%H:%M:%S)"
    if ! run_make fetch STACK="$name"; then
      echo "!!!! [$name] fetch 失败（产物可能仍在实例上，别急着 down）"
      [ "$rc" = 0 ] && rc=2
    fi
  fi

  if [ "$DO_DOWN" = 1 ]; then
    echo "----- [$name] down $(date +%H:%M:%S)"
    if ! run_make down STACK="$name" CONFIRM=1; then
      echo "!!!! [$name] down 失败 —— 资源可能还在计费，请手工 make down STACK=$name CONFIRM=1"
      [ "$rc" = 0 ] && rc=3
    fi
  else
    echo "----- [$name] 保留实例（--no-down）；用完记得 make down STACK=$name CONFIRM=1"
  fi

  echo "================================================================"
  echo "[$name] 结束 rc=$rc $(date -Is)  日志：$log"
  return "$rc"
}

LIVE_PIDS=""
live_count() {
  local n=0 p
  for p in $LIVE_PIDS; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
  echo "$n"
}
reap() {
  local new="" p
  for p in $LIVE_PIDS; do kill -0 "$p" 2>/dev/null && new="$new $p"; done
  LIVE_PIDS="$new"
}

T0=$(date +%s)
echo "  ▶ 启动流水线（并行上限 ${PAR}）"
launched=0
for i in $SEL; do
  while [ "$(live_count)" -ge "$PAR" ]; do sleep 5; done
  nm="$(eff "$i" name)"
  rcf="$MATRIX_DIR/$nm.rc"
  # 子壳里再显式 set +e：外层是 set -e，run_stack 返回非 0 会直接终结子壳，
  # 那样这行写 rc 就永远执行不到。
  ( set +e; run_stack "$i"; echo "$?" > "$rcf" ) &
  LIVE_PIDS="$LIVE_PIDS $!"
  launched=$((launched + 1))
  printf '      [%d/%d] stack=%s 已启动\n' "$launched" "$NSEL" "$nm"
done

HB=$(date +%s)
while :; do
  reap
  [ -z "$LIVE_PIDS" ] && break
  sleep 15
  now=$(date +%s)
  if [ $((now - HB)) -ge 60 ]; then
    HB=$now
    el=$((now - T0))
    printf '  ⏳ 进行中 %d 套，已用 %dm%02ds\n' "$(live_count)" $((el / 60)) $((el % 60))
  fi
done

# ============================================================================
# 7. 结果
# ============================================================================
echo
echo "=== 结果 ==="
FAIL=0
NAMES=""
for i in $SEL; do
  nm="$(eff "$i" name)"
  NAMES="$NAMES $nm"
  rc="$(cat "$MATRIX_DIR/$nm.rc" 2>/dev/null || echo '?')"
  last="$(grep -v '^$' "$LOG_DIR/$nm.log" 2>/dev/null | tail -1 | cut -c1-90)"
  case "$rc" in
    0) printf '  ✅ %-6s rc=0\n' "$nm" ;;
    *) printf '  ❌ %-6s rc=%-3s %s\n' "$nm" "$rc" "$last"; FAIL=1 ;;
  esac
done

if [ "$DO_FETCH" = 1 ] && [ -x "$HERE/matrix-summary.sh" ]; then
  echo
  if ! "$HERE/matrix-summary.sh" --matrix-dir "$MATRIX_DIR" \
        --stacks "${NAMES# }" --title "并行矩阵 $TS"; then
    warn "汇总失败（各栈原始产物仍在 results/<stack>/，可手工查看）"
  fi
fi

EL=$(( $(date +%s) - T0 ))
echo
echo "总耗时 ${EL}s。日志目录：$MATRIX_DIR"
if [ "$FAIL" = 1 ]; then
  echo "有栈未成功 —— 逐栈看日志： $LOG_DIR/<stack>.log"
  exit 1
fi
exit 0
