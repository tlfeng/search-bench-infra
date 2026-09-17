SHELL   := /bin/bash
ROOT    := $(shell pwd)
TFDIR   := $(ROOT)/terraform
SCRIPTS := $(ROOT)/scripts

# 优先用项目内 bin/terraform（官方二进制，不污染系统），否则退回 PATH 里的
TERRAFORM ?= $(if $(wildcard $(ROOT)/bin/terraform),$(ROOT)/bin/terraform,terraform)

# build-image.sh / fetch-results.sh 会直接调用 terraform 与 aliyun CLI，
# 因此把它们的目录显式注入 PATH（沙箱默认 PATH 里没有 /opt/homebrew/bin）。
export PATH := $(dir $(TERRAFORM)):/opt/homebrew/bin:$(HOME)/.local/bin:$(PATH)

# ---------- 多环境切片（STACK）----------
# STACK 是所有可变状态的命名空间，贯穿五层，缺一层就会互相踩：
#   云上资源名（含 region 内全局唯一的 SSH 密钥对）/ terraform workspace（即 state）
#   / provider 缓存 / 本地产物目录 / OSS 归档前缀
#
# 不传时是 default：资源名退化为 esbench-perf，与历史命名逐字一致
# （已用真实 state 验证：plan 为 0 to add / 0 to change / 0 to destroy）。
#
#   make up    STACK=a PROFILE=x86-main ZONE=cn-hangzhou-b
#   make bench STACK=a TRACK=geonames CLIENTS=8
#   make stacks                     列出所有 stack，看清云端有几套在烧钱
#   make down  STACK=a CONFIRM=1    非 default 必须显式确认
#
# 两套并存时务必用不同 ZONE（见 README 2.8）：同可用区的 ESSD 后端带宽是共享的，
# 会让两套环境的测量互相污染。
STACK ?= default
export STACK

# provider 缓存与「当前 workspace 指针」按 stack 隔离，避免并发 init/apply 互相改写
TF_DATA_DIR := $(ROOT)/.stacks/$(STACK)/.terraform
export TF_DATA_DIR

# 本地产物目录同样按 stack 切片，但 default 保持历史路径 results/（不套子目录）。
# 与资源命名同一条原则：引入切片键不应改变 default 下的既有行为，
# 否则老产物会「凭空消失」，用户以为丢了数据。
LOCAL_DIR := $(if $(filter default,$(STACK)),$(ROOT)/results,$(ROOT)/results/$(STACK))
export LOCAL_DIR

# terraform 的统一入口：负责 provider 预热与 workspace 切换（见 scripts/tf.sh 注释）
TF := $(SCRIPTS)/tf.sh

# ---------- 环境元数据：make up 时落盘，操作这套环境时缺省回读 ----------
# 解决「up 用 arm-debug、bench 忘传 PROFILE」的静默错配：按默认档推导会让
#   --tag arch 错标成 x86、--expected-nodes 退化成 1（双节点只起来一个也会被判就绪）。
# 规则只有一条：命令行/环境变量显式给的值永远优先；meta 只补缺省。
# 且只对「操作已在运行环境」的目标回读 —— image-* / local-validate 等构建类目标
# 不受影响，否则上次 up 的档位会把镜像架构静默带偏。
META_FILE := $(ROOT)/.stacks/$(STACK)/meta
META_EXISTS := $(if $(wildcard $(META_FILE)),1,)
ifneq ($(wildcard $(META_FILE)),)
META_PROFILE := $(strip $(shell sed -n 's/^PROFILE=//p' $(META_FILE)))
META_ENGINE  := $(strip $(shell sed -n 's/^ENGINE=//p'  $(META_FILE)))
META_UP_AT   := $(strip $(shell sed -n 's/^UP_AT=//p'   $(META_FILE)))
endif
META_CONSUMERS := up status bench fetch down plan run
ifneq ($(filter $(META_CONSUMERS),$(if $(MAKECMDGOALS),$(MAKECMDGOALS),help)),)
META_ACTIVE := 1
endif
ifeq ($(strip $(META_ACTIVE)$(META_EXISTS)),11)
# 显式性看 origin：command line / environment = 用户给的，一字不改；
# undefined（PROFILE ?= 还没执行到）= 没给，回读 meta。
ifneq ($(filter command line environment,$(origin PROFILE)),)
else ifneq ($(strip $(META_PROFILE)),)
PROFILE := $(META_PROFILE)
META_APPLIED += PROFILE
endif
ifneq ($(filter command line environment,$(origin ENGINE)),)
else ifneq ($(strip $(META_ENGINE)),)
ENGINE := $(META_ENGINE)
META_APPLIED += ENGINE
endif
endif

# ---------- 档位 ----------
# debug(2C8G×1) | x86-cheap(8C32G) | x86-main(16C64G) | arm-cheap(8C32G) | arm-main(16C64G)
# 建议从 debug 起步把链路跑通，再 *-cheap 验证双节点，最后 *-main 出正式数据。
PROFILE ?= debug

# 调试形态（debug / arm-debug 两档通用）：单节点 + 高效云盘小盘，整套约 1 元/时
ifneq ($(filter debug arm-debug,$(PROFILE)),)
  ES_NODES        := 1
  # 注意：g8y/g8i 等 ARM 与新一代 x86 机型**不支持高效云盘**（cloud_efficiency），
  # 数据盘/系统盘都必须用 cloud_essd（实测 InvalidDataDiskCategory.ValueNotSupported）
  ES_DISK_CAT     := cloud_essd
  ES_DISK_SIZE    := 40
  RALLY_DISK_CAT  := cloud_essd
  RALLY_DISK_SIZE := 40
else
  ES_NODES        := 2
  # 磁盘按成本收紧：ESSD 0.0021 元/GiB/时，系统盘与数据盘同价。
  # ES 数据 100G：geonames 2.8G + merge 峰值 <10G，HNSW 2M 3.9G，足够；
  # ESSD PL1 的 350MB/s 上限与容量无关，500G 不带来性能，不够可在线扩容。
  ES_DISK_CAT     := cloud_essd
  ES_DISK_SIZE    := 100
  RALLY_DISK_CAT  := cloud_essd
  RALLY_DISK_SIZE := 40
endif

# rally 架构：只有纯 x86 的 debug 档用 x86（让跑通前只需一套镜像）；
# arm-debug 本身就是 ARM，rally 自然也用 ARM，同样只需一套 ARM 镜像。
# 注意：不要在赋值行尾写注释 —— Make 会把注释前的空白并入变量值，
# 结果 $(TERRAFORM) 收到 "x86      " 这种带尾随空格的值，直接卡在 validation。
ifeq ($(PROFILE),debug)
  DEFAULT_RALLY_ON := x86
else
  DEFAULT_RALLY_ON := arm
endif

# 注意判断方向：debug 既不以 x86 也不以 arm 开头，所以按「arm% 才算 ARM」判断，
# 其余一律 x86_64，否则 debug 会被误判成 ARM。
ARCH := $(if $(filter arm%,$(PROFILE)),aarch64,x86_64)

# 构建镜像的临时机型统一用 2C8G：构建过程以网络下载为主、不吃 CPU，
# 用 large 而非 xlarge 可把单次构建成本从约 0.8 元压到约 0.2 元。
BUILD_TYPE := $(if $(filter arm%,$(PROFILE)),ecs.g8y.large,ecs.g8i.large)

# rally 客户端架构，独立于 ES：默认 arm（算力比同规格 x86 便宜约 23.5%，含盘约 17%~22%）。
# rally 只发 HTTP 请求，计算都在服务端，架构不影响服务端测量；
# 前提是 ARM 单核算力能压满服务端（用 pidstat 看 rally 进程 %CPU）。
# 若发现客户端先饱和，改成 RALLY_ON=x86 即可。
RALLY_ON         ?= $(DEFAULT_RALLY_ON)
RALLY_ARCH       := $(if $(filter arm,$(RALLY_ON)),aarch64,x86_64)
RALLY_BUILD_TYPE := $(if $(filter arm,$(RALLY_ON)),ecs.g8y.large,ecs.g8i.large)

# ---------- bench 时可传参数（都有默认值，不传也能跑） ----------
# TRACK=geonames|hnsw2m|nested    数据集（默认 geonames）
# CHALLENGE=<挑战名>              默认 append-no-conflicts
# CLIENTS=<并发数>                不传则用 track 自带默认
# ENGINE_NAME=es|ez               只用于打 user-tags，便于事后筛选
# RUN_ID=<场次 id>                仅 fetch 时用
# FROM=oss|instance               仅 fetch 时用，默认 oss；本机无 ossutil64 会自动回退 instance（需实例还在）
# LOCAL_DIR=<路径>                仅 fetch 时用，默认 results/
TRACK ?=
CHALLENGE ?=
CLIENTS ?=
ENGINE_NAME ?=
RUN_ID ?=
# ENGINE_NAME 未显式传时按引擎派生（上面 meta 回读后的 ENGINE 也算数）：
# easysearch → ez，--distribution-version=7.10.2 随之自动补上（esrally 拒连自报 2.4.0 的集群）；
# elasticsearch → es。user-tags 里始终有 engine=…，事后筛场次不靠回忆。
# 显式传 ENGINE_NAME=（置空）可退出该行为；传错值优先级最高，按传的算。
ifeq ($(filter command line environment,$(origin ENGINE_NAME)),)
ENGINE_NAME := $(if $(filter easysearch ez,$(ENGINE)),ez,es)
endif

# ---------- 引擎 ----------
ENGINE ?= elasticsearch
# 两个引擎统一用同一个 9 位口令：9 位是 easysearch 密码策略的下限，
# 对 elasticsearch 同样合规，省掉按引擎派生。镜像构建（--es-pass）与开机
# （tfvars es_password / rally 的 /etc/es-oss.conf）共用这一个变量。
# 注意：引擎真实密码烘焙在建镜像时，改这个值后存量 ES 镜像要 FORCE=1 重建。
ENGINE_PASS ?= Qwer@1234

# 系统盘 40G 足够（OS+引擎+语料/JDK）；ESSD 系统盘与数据盘同价，
# 盘小自定义镜像的快照存储费也同步下降。数据一律放数据盘 /data。
SYSTEM_DISK_SIZE := 40

# ---------- 计费（按量 / 竞价） ----------
# 三个都不传 = 沿用 terraform.tfvars 里的值（当前为按量）。
# 命令行传了就覆盖 tfvars，用于「同一套 tfvars 临时跑一轮便宜的调试」：
#   make up USE_SPOT=1              整套（ES + rally）竞价
#   make up SPOT_RALLY=1            ES 按量 + rally 竞价（推荐：ES 稳定，rally 被回收只重跑）
#   make up USE_SPOT=1 SPOT_ES=0    整套竞价，但 ES 强制按量
# 取值 1/true/yes/on = 竞价，0/false/no/off = 按量。
# 注意 spot_strategy 是 ForceNew：切换计费方式会重建实例，数据盘 delete_with_instance=true
# 会跟着销毁——对已有环境改这个值之前先 make fetch，否则产物随实例一起没了。
USE_SPOT   ?=
SPOT_ES    ?=
SPOT_RALLY ?=

# 归一化成 terraform 认的 true/false；大小写不敏感，避免 SPOT_ES=True 被静默当成按量
asbool = $(if $(filter 1 true yes on,$(shell echo $(1) | tr 'A-Z' 'a-z')),true,false)

SPOT_ARGS :=
ifneq ($(strip $(USE_SPOT)),)
SPOT_ARGS += -var="use_spot=$(call asbool,$(USE_SPOT))"
endif
ifneq ($(strip $(SPOT_ES)),)
SPOT_ARGS += -var="es_use_spot=$(call asbool,$(SPOT_ES))"
endif
ifneq ($(strip $(SPOT_RALLY)),)
SPOT_ARGS += -var="rally_use_spot=$(call asbool,$(SPOT_RALLY))"
endif

# plan / up 共用同一份变量清单：两处各写一遍迟早会漏（新增变量只改一处）
TF_VARS := -var="profile=$(PROFILE)" \
           -var="stack=$(STACK)" \
           -var="rally_arch=$(RALLY_ON)" \
           -var="engine=$(ENGINE)" \
           -var="es_password=$(ENGINE_PASS)" \
           -var="es_node_count=$(ES_NODES)" \
           -var="es_data_disk_category=$(ES_DISK_CAT)" \
           -var="es_data_disk_size=$(ES_DISK_SIZE)" \
           -var="rally_data_disk_category=$(RALLY_DISK_CAT)" \
           -var="rally_data_disk_size=$(RALLY_DISK_SIZE)" \
           -var="system_disk_size=$(SYSTEM_DISK_SIZE)"

# ---------- 按 stack 错开可用区与网段（可选，多栈并存时强烈建议）----------
# 不传则沿用 terraform.tfvars 里的 zone_id / vpc_cidr / vswitch_cidr。
#   make up STACK=a ZONE=cn-hangzhou-b
#   make up STACK=b ZONE=cn-hangzhou-c VPC_CIDR=172.17.0.0/16 VSWITCH_CIDR=172.17.1.0/24
# 为什么必须错开可用区：同可用区两套实例的后端存储带宽是共享的，
# 会让「并发对照」变成「互相干扰」（见 README 2.8 的测量纪律）。
ZONE         ?=
VPC_CIDR     ?=
VSWITCH_CIDR ?=
ifneq ($(strip $(ZONE)),)
TF_VARS += -var="zone_id=$(ZONE)"
endif
ifneq ($(strip $(VPC_CIDR)),)
TF_VARS += -var="vpc_cidr=$(VPC_CIDR)"
endif
ifneq ($(strip $(VSWITCH_CIDR)),)
TF_VARS += -var="vswitch_cidr=$(VSWITCH_CIDR)"
endif

# OSS 归档前缀：非 default stack 自动追加 /<STACK>。
# 不加后缀的话，make fetch（不带 RUN_ID = 拉整个前缀）会把多套环境的产物混进同一目录。
# 用 $(strip) 包一层：Make 的赋值行尾空格会进变量值，直接判等会静默失效（见文件头警告）。
OSS_PREFIX_BASE ?= esrally-results
ifneq ($(strip $(STACK)),default)
TF_VARS += -var="oss_prefix=$(OSS_PREFIX_BASE)/$(STACK)"
endif

# 版本：ES 与 easysearch 各自的默认值。升级 = 改这里（或命令行 ES_VER=… 覆盖）
# -> 建新镜像（镜像名含版本，天然与旧版并存）-> make image-use 切换指向。
# 刻意不做「自动拉最新」：版本是被测对象的一部分，静默升级会让两轮结果不可比。
ES_VER ?= 8.19.21
# easysearch 用 snapshot/bundle 的 2.4.0-2969：发布包本体不含 JDK，
# bundle 自带 JDK，省去 initialize.sh 现拉 ~200MB（慢且依赖外网）。
EZ_VER ?= 2.4.0-2969
ENGINE_VER := $(if $(filter easysearch,$(ENGINE)),$(EZ_VER),$(ES_VER))
# bundle 包只在 snapshot/bundle/ 路径下
EZ_CHANNEL ?= snapshot
EZ_BUNDLE  ?= 1
# esrally 版本：编入 rally 镜像名（esbench-rally-<RALLY_VER>-<arch>），并传给 install.sh
RALLY_VER ?= 2.12.0
BASE_IMG ?=                   # 基础镜像正则，留空用默认 ^aliyun_4_(x64|arm64)_20G_alibase_[0-9]{8}[.]vhd$；需要 Rocky 时传 '^rockylinux_9'

.PHONY: help init validate fmt plan corpus balance local-validate setup image-all image-es image-rally image-ls image-use image-fix-names up status \
        ssh-rally ssh-es1 ssh-es2 bench run matrix fetch down clean tail-rally stacks

help:
	@echo "search-bench-infra —— 搜索引擎压测基础设施（esrally on 阿里云 ECS，Terraform 自动化）"
	@echo
	@echo "档位（PROFILE，当前默认 $(PROFILE)）—— 只决定 ES 节点的架构与规格："
	@echo "  debug       x86 2C8G  x1 节点 <- 从这开始，整套约 1.4 元/小时（竞价约 0.5）"
	@echo "  arm-debug   ARM 2C8G  x1 节点 <- 更便宜（约 1.1 元/时），且能提前暴露 aarch64 兼容性问题"
	@echo "  x86-cheap   x86 8C32G        <- 再验证「双节点集群发现」"
	@echo "  x86-main    x86 16C64G       <- 主力档，与基线算力对齐"
	@echo "  arm-cheap   ARM 8C32G"
	@echo "  arm-main    ARM 16C64G"
	@echo
	@echo "rally 客户端架构（RALLY_ON，当前默认 $(RALLY_ON)）—— 独立于 ES："
	@echo "  arm   ARM 4C16G/8C32G，算力比同规格 x86 便宜约 23.5%（默认）"
	@echo "  x86   若实测 ARM 单核压不满服务端，改回这个"
	@echo
	@echo "计费（USE_SPOT / SPOT_ES / SPOT_RALLY，三者都不传则沿用 terraform.tfvars）："
	@echo "  make up USE_SPOT=1            整套竞价（约按量 2 折，可能被回收）"
	@echo "  make up SPOT_RALLY=1          ES 按量 + rally 竞价（推荐：ES 稳定，rally 被回收只重跑）"
	@echo "  1/true/yes/on = 竞价，0/false/no/off = 按量；正式出报告的轮次不要开"
	@echo "  改计费方式会重建实例（数据盘一起销毁），先 make fetch 取回产物"
	@echo
	@echo "首次使用（0 费用 -> 最省）："
	@echo "  make setup                    新机器引导：生成 tfvars + 预热 provider + 自检（凭据先手动 aliyun configure）"
	@echo "  make corpus                   准备语料离线包（本机执行，不产生云费用）"
	@echo "  make balance                  查账户余额与当月消耗（需 BSS 只读权限）"
	@echo "  make local-validate ROLE=all  用 Docker 在本地验证 install.sh（0 云费用）"
	@echo "  make image-rally PROFILE=arm-cheap WITH_CORPUS=1  rally 镜像（语料必须带）"
	@echo "     注意：不带 PROFILE 时默认 debug 档 -> rally 走 x86；四轮对照用的是 ARM，务必带 PROFILE=arm-*"
	@echo "  make image-es  PROFILE=arm-debug"
	@echo "     版本都是参数：ES_VER=8.19.21（默认）/ EZ_VER=2.4.0-2969 / RALLY_VER=2.12.0。"
	@echo "     升级 = 传新值建新镜像（名字含版本，与旧版并存）-> make image-use 切换指向；"
	@echo "     刻意不做自动拉最新——版本是被测对象的一部分，静默升级会让两轮结果不可比。"
	@echo
	@echo "常用："
	@echo "  make up                       按档位创建 ECS（ES + rally）"
	@echo "  make bench TRACK=geonames CLIENTS=8"
	@echo "     （PROFILE/ENGINE 缺省回读 up 记录 .stacks/<STACK>/meta，显式传参永远优先）"
	@echo "  make run PROFILE=… [ENGINE=…] [CLIENTS=…] [STACK=…]"
	@echo "                                一条命令跑完一轮 up→bench→fetch→down（失败保 fetch/down）"
	@echo "  make run TEST_MODE=1          秒级链路验证；DRY=1 只出计划（0 费用）；KEEP=1 保留实例"
	@echo "  make bench TEST_MODE=1        极小数据集，秒级完成，只用于打通链路"
	@echo "  make fetch [FROM=instance]    取回产物到 results/<stack>/（默认从 OSS 拉）"
	@echo "  make down                     销毁全部资源（省钱）"
	@echo "  make image-ls                 查看镜像台账，标注 tfvars 当前指向"
	@echo "  make image-use ENGINE=ez ARCH=arm   切换 tfvars 指向的镜像（同步改 engine）"
	@echo "  make image-fix-names          存量镜像名补版本（已含版本的不动）"
	@echo
	@echo "多环境并存（STACK，当前 $(STACK)）—— 同时跑多套互不干扰的环境："
	@echo "  STACK 会贯穿资源名 / terraform workspace（state）/ 本地产物目录 / OSS 前缀，"
	@echo "  缺一层就会互相踩。不传 = default，资源名与历史逐字一致，存量环境零重建。"
	@echo "  make up    STACK=a PROFILE=x86-main ZONE=cn-hangzhou-b"
	@echo "  make bench STACK=a TRACK=geonames CLIENTS=8"
	@echo "  make fetch STACK=a            -> results/a/"
	@echo "  make status STACK=a           看这一套的 IP"
	@echo "  make down  STACK=a CONFIRM=1  非 default 必须显式确认（防打错 stack 误删别人环境）"
	@echo "  make stacks                   列出所有 stack，看清云端到底有几套在烧钱"
	@echo "  make matrix [MATRIX=...]      按 stacks.yaml 并行跑多套并汇总对照表"
	@echo "  ⚠️ 并发只用于冒烟/链路验证/交叉初筛；正式出报告的轮次仍应串行（README 2.8）"
	@echo
	@echo "排查（都不产生费用）："
	@echo "  make validate                 HCL 语法检查"
	@echo "  make plan                     预览将要创建的资源"
	@echo "  make status                   查看 IP、target-hosts、当前档位与计费方式"
	@echo "  make ssh-rally / ssh-es1      直接登录"
	@echo "  make tail-rally               看 rally 机初始化日志"
	@echo "  make stacks                   列出全部 stack（workspace + 产物目录）"
	@echo
	@echo "推荐推进顺序："
	@echo "  1) make corpus"
	@echo "     make image-rally PROFILE=arm-debug WITH_CORPUS=1"
	@echo "     make image-es    PROFILE=arm-debug"
	@echo "  2) make up PROFILE=arm-debug && make bench TEST_MODE=1 && make down"
	@echo "  3) make up PROFILE=x86-cheap    验证双节点集群发现（必须 number_of_nodes=2）"
	@echo "  4) 四轮对照：x86/ARM × EZ/ES。串行省钱（每轮 make down）；"
	@echo "     要让第 1 轮与第 4 轮不受时段漂移影响，用 make matrix 并发跑（务必错开 ZONE）"

# provider 预热与 workspace 切换都由 scripts/tf.sh 负责。
# init 走 TF_CLI_CONFIG_FILE（本地 provider 镜像），否则会去查 registry，
# 国内网络一抖就失败；不加 -upgrade（lock 文件已锁版本）。
init:
	@$(TF) init

validate: init
	@$(TF) validate
	@echo "  ✅ HCL 语法与引用校验通过（未创建任何资源，0 元）"

fmt:
	cd $(TFDIR) && $(TERRAFORM) fmt -recursive

plan: init
	@$(TF) plan $(TF_VARS) $(SPOT_ARGS)

# 用变量拼接而不是 $(if) 内联：后者在参数为空时会留下悬空的续行符，脆弱且难读
ES_ARGS := --role es --arch $(ARCH) --instance-type $(BUILD_TYPE) --engine $(ENGINE) --es-pass $(ENGINE_PASS)
ES_ARGS += --version $(ENGINE_VER)
ifeq ($(strip $(ENGINE)),easysearch)
ES_ARGS += --es-channel $(EZ_CHANNEL)
ifeq ($(strip $(EZ_BUNDLE)),1)
ES_ARGS += --es-bundle
endif
endif

RALLY_ARGS := --role rally --arch $(RALLY_ARCH) --instance-type $(RALLY_BUILD_TYPE)
RALLY_ARGS += --version $(RALLY_VER)

ifneq ($(strip $(BASE_IMG)),)
ES_ARGS    += --base-image-regex '$(BASE_IMG)'
RALLY_ARGS += --base-image-regex '$(BASE_IMG)'
endif

# WITH_CORPUS=1：把 esrally 语料烘焙进 rally 镜像。
# 必须烘焙 —— track 定义走 github、语料走 GCS，国内 ECS 两者都拉不到。
# 语料包由 `make corpus` 生成本地文件，默认取 corpus/geonames-corpus.tar.gz。
CORPUS_PKG ?= $(ROOT)/corpus/$(or $(TRACK),geonames)-corpus.tar.gz
ifeq ($(strip $(WITH_CORPUS)),1)
RALLY_ARGS += --with-corpus $(CORPUS_PKG)
endif

BENCH_ARGS := --track $(or $(TRACK),geonames) --challenge $(or $(CHALLENGE),append-no-conflicts)
# 就绪门禁必须带期望节点数：run-bench.sh 默认只期望 1 个节点，而**单节点集群也会报 green**，
# 不传就等于放弃了「集群发现是否成功」这个检查（双节点只起来一个也会被判定就绪）。
BENCH_ARGS += --expected-nodes $(ES_NODES)
# geonames 的并发参数叫 bulk_indexing_clients，不是 clients；传错等于没传
ifneq ($(strip $(CLIENTS)),)
BENCH_ARGS += --clients $(CLIENTS) --clients-param $(or $(CLIENTS_PARAM),bulk_indexing_clients)
endif
# CODEC=default|zstd|zstd-v2|zstd-v3|best-compression（默认 default = 不注入，保持 track 原样）
# 不传 CODEC 时 run-bench.sh 自己也默认 default，这里显式传只是为了在 `make bench` 的
# 回显里看得见本轮用的 codec，避免「以为压的是 zstd、其实压的默认」。
CODEC ?= default
BENCH_ARGS += --codec $(CODEC)
# 密码不在这里传：run-bench 从 rally 机的 /etc/es-oss.conf 读取（由 tfvars es_password 注入）
ifneq ($(strip $(ENGINE_NAME)),)
BENCH_ARGS += --tag engine=$(ENGINE_NAME)
endif
# 同样按 arm% 判断：debug 档要标 x86，不能落到 arm
BENCH_ARGS += --tag arch=$(if $(filter arm%,$(PROFILE)),arm,x86)

# TEST_MODE=1：用 esrally 的 --test-mode（极小数据集，秒级完成），只用于打通链路
ifeq ($(strip $(TEST_MODE)),1)
BENCH_ARGS += --test-mode
endif

# easysearch 自报版本 2.4.0，esrally 要求集群版本 >= 6.8.0，必须显式告知真实血统
# （easysearch 2.x 基于 ES 7.10.2）。ENGINE_NAME=ez 或 ENGINE=easysearch 时自动带上，
# 也可手动 DIST_VERSION=7.10.2 覆盖。
DIST_VERSION ?= $(if $(filter ez easysearch,$(or $(ENGINE_NAME),$(ENGINE))),7.10.2,)
ifneq ($(strip $(DIST_VERSION)),)
BENCH_ARGS += --dist-version $(DIST_VERSION)
endif

# 本地容器验证：在 Docker 里跑 install.sh，0 费用地把「建镜像」逻辑验掉。
# 默认用 anolisos:23 —— 它是 Alibaba Cloud Linux 4 的上游，Python 3.10，与目标最接近。
LV_ARGS := --image $(or $(OS_IMAGE),openanolis/anolisos:23) --engine $(ENGINE)
ifneq ($(strip $(ROLE)),)
LV_ARGS += --role $(ROLE)
else
LV_ARGS += --role all
endif
ifeq ($(strip $(WITH_CORPUS)),1)
LV_ARGS += --with-corpus
endif
ifneq ($(strip $(ES_VER)),)
LV_ARGS += --version $(ENGINE_VER)
endif

# 准备语料离线包（本机执行，不产生云费用）
corpus:
	$(SCRIPTS)/prepare-corpus.sh --track $(or $(TRACK),geonames) --out corpus

# 本地容器验证 install.sh（需要 Docker，0 云费用）
local-validate:
	$(SCRIPTS)/local-validate.sh $(LV_ARGS)

# 新机器一键引导：生成 tfvars（自动填公钥/出口 IP）+ 预热 provider + 自检。
# 凭据需先手动执行 `aliyun configure`（AK 来自 RAM 控制台创建用户的结果）。
setup:
	$(SCRIPTS)/bootstrap.sh all

# 查账户余额与当月消耗（需要 RAM 用户具备 BSS 只读权限，纯只读）
balance:
	$(SCRIPTS)/bss-report.sh $(if $(MONTH),--month $(MONTH),)

image-all: image-es image-rally

image-es:
	$(SCRIPTS)/build-image.sh $(ES_ARGS)

image-rally:
	$(SCRIPTS)/build-image.sh $(RALLY_ARGS)

# 镜像台账：列出已构建的全部镜像，标注 tfvars 当前指向哪张（0 费用，纯本地）
image-ls:
	$(SCRIPTS)/image.sh ls

# 切换 tfvars 指向的镜像（防「引擎配置与镜像」错配），如：
#   make image-use ENGINE=easysearch ARCH=x86    # 切 ES 镜像并同步 engine
#   make image-use --id m-xxxx                   # 按镜像 ID 切
image-use:
	$(SCRIPTS)/image.sh use $(if $(ENGINE),--engine $(ENGINE),) $(if $(ARCH),--arch $(ARCH),) $(if $(ROLE),--role $(ROLE),) $(if $(ID),--id $(ID),)

# 给存量镜像名补版本号（名字里已含版本的不动），并同步台账
image-fix-names:
	$(SCRIPTS)/image.sh fix-names

up: init
ifneq ($(strip $(META_APPLIED)),)
	@echo "  [meta] $(META_APPLIED) 缺省值取自 up 记录：PROFILE=$(PROFILE) ENGINE=$(ENGINE)"
endif
	@$(TF) apply -auto-approve $(TF_VARS) $(SPOT_ARGS)
	@mkdir -p $(ROOT)/.stacks/$(STACK)
	@printf 'UP_AT=%s\nPROFILE=%s\nENGINE=%s\nES_NODES=%s\nARCH=%s\n' \
	  "$$(date '+%F %T')" '$(PROFILE)' '$(ENGINE)' '$(ES_NODES)' '$(ARCH)' \
	  > $(META_FILE)
	@echo "  环境配置已记录到 .stacks/$(STACK)/meta（bench/status 不传 PROFILE 时自动回读）"
	@$(MAKE) --no-print-directory status STACK=$(STACK)

status:
	@echo "  stack   : $(STACK)$(if $(filter default,$(STACK)),  （未切片，资源名无后缀）,  （产物在 results/$(STACK)/）)"
	@echo "  zone    : $(if $(strip $(ZONE)),$(ZONE),见 terraform.tfvars 的 zone_id)$(if $(filter default,$(STACK)),,  <- 多栈并存时务必各栈不同)"
ifneq ($(wildcard $(META_FILE)),)
	@echo "  记录    : $(META_UP_AT) up → PROFILE=$(META_PROFILE) ENGINE=$(META_ENGINE)$(if $(filter-out $(META_PROFILE),$(PROFILE)),  ⚠️ 与传入的 PROFILE=$(PROFILE) 不一致,)"
endif
	@$(TF) output

ssh-rally:
	@ssh -o StrictHostKeyChecking=no root@$$($(TF) output -raw rally_public_ip)

ssh-es1:
	@ssh -o StrictHostKeyChecking=no root@$$($(TF) output -json es_public_ips | tr -d '[]" ' | cut -d, -f1)

ssh-es2:
	@ssh -o StrictHostKeyChecking=no root@$$($(TF) output -json es_public_ips | tr -d '[]" ' | cut -d, -f2)

tail-rally:
	@ssh -o StrictHostKeyChecking=no root@$$($(TF) output -raw rally_public_ip) 'tail -50 /var/log/rally-init.log'

# 列出全部 stack：本地（workspace / 产物 / provider 缓存）+ 云端（仍在计费的实例）。
# 并发多套时最容易忘的就是「云端还有一套在烧钱」，这条命令是那个提醒。
stacks:
	@$(SCRIPTS)/stacks.sh $(if $(LOCAL_ONLY),--local-only,)

bench:
ifneq ($(strip $(META_APPLIED)),)
	@echo "  [meta] $(META_APPLIED) 缺省值取自 up 记录：PROFILE=$(PROFILE) ENGINE=$(ENGINE) → ENGINE_NAME=$(ENGINE_NAME)（.stacks/$(STACK)/meta）"
endif
ifeq ($(strip $(META_EXISTS)),1)
ifneq ($(strip $(META_PROFILE)),)
ifneq ($(META_PROFILE),$(PROFILE))
	@echo "  ⚠️  传入 PROFILE=$(PROFILE) 与 up 记录的 $(META_PROFILE) 不一致 —— 确认压的是这套环境"
endif
endif
else
	@echo "  ⚠️  无 up 记录（.stacks/$(STACK)/meta 不存在）：就绪门禁节点数与 arch 标签按 PROFILE=$(PROFILE) 推导 —— 环境不是这套配置就显式传 PROFILE 或重跑 make up"
endif
	$(SCRIPTS)/run-bench.sh $(BENCH_ARGS)

# 一条命令跑完一轮：up → bench → fetch → down（README 2.5 串行纪律的自动化形态）。
# 复用 bench-matrix 的单栈流水线：bench 失败也 fetch、任何失败也 down，跑完出汇总表。
#   make run PROFILE=arm-main ENGINE=easysearch CLIENTS=8
#   make run TEST_MODE=1   秒级链路验证；DRY=1 只出计划与预检（0 费用）
#   make run KEEP=1        保留实例排查（--no-down），用完手工 make down STACK=$(STACK) CONFIRM=1
# 生成的单栈定义留在 .stacks/$(STACK)/last-run.yaml —— 既是输入也是运行留档。
RUN_YAML := $(ROOT)/.stacks/$(STACK)/last-run.yaml
run:
	@mkdir -p $(ROOT)/.stacks/$(STACK)
	@{ printf 'stacks:\n'; \
	   printf '  - name: $(STACK)\n'; \
	   printf '    profile: $(PROFILE)\n'; \
	   printf '    engine: $(ENGINE)\n'; \
	   [ -n "$(TRACK)" ] && printf '    track: $(TRACK)\n'; \
	   [ -n "$(CHALLENGE)" ] && printf '    challenge: $(CHALLENGE)\n'; \
	   [ -n "$(CLIENTS)" ] && printf '    clients: $(CLIENTS)\n'; \
	   printf '    codec: $(CODEC)\n'; \
	   printf '    rally_on: $(RALLY_ON)\n'; \
	   [ -n "$(ZONE)" ] && printf '    zone: $(ZONE)\n'; \
	   [ -n "$(VPC_CIDR)" ] && printf '    vpc_cidr: $(VPC_CIDR)\n'; \
	   [ -n "$(VSWITCH_CIDR)" ] && printf '    vswitch_cidr: $(VSWITCH_CIDR)\n'; \
	   [ -n "$(strip $(USE_SPOT))" ] && printf '    use_spot: $(USE_SPOT)\n'; \
	   [ -n "$(strip $(SPOT_ES))" ] && printf '    spot_es: $(SPOT_ES)\n'; \
	   [ -n "$(strip $(SPOT_RALLY))" ] && printf '    spot_rally: $(SPOT_RALLY)\n'; \
	   true; } > $(RUN_YAML)
	@echo "  单栈定义 -> $(RUN_YAML)；流程 up → bench → fetch → down（KEEP=1 时保留实例）"
	# 这里必须中立化 STACK：bench-matrix 的栈身份来自上面生成的 yaml，不来自环境变量；
	# 而它会拒绝非 default 的 STACK（防止 make matrix 误解语义）。
	# 不清掉的话，make run STACK=x 会被自己的调用链挡在门外。
	@env -u STACK $(SCRIPTS)/bench-matrix.sh --file $(RUN_YAML) --parallel 1 --yes \
	  $(if $(filter 1,$(TEST_MODE)),--test-mode,) \
	  $(if $(filter 1,$(DRY)),--dry-run,) \
	  $(if $(filter 1,$(KEEP)),--no-down,)

# 并行矩阵：按 stacks.yaml 同时跑多套环境，跑完汇总成一张对照表。
#   make matrix                     用 ./stacks.yaml
#   make matrix MATRIX=path/to.yaml
#   make matrix MATRIX_ARGS="--stacks a,b --dry-run"
MATRIX ?= $(ROOT)/stacks.yaml
MATRIX_ARGS ?= $(if $(MATRIX),--file $(MATRIX),)
matrix:
	$(SCRIPTS)/bench-matrix.sh $(MATRIX_ARGS) $(EXTRA_ARGS)

fetch:
	$(SCRIPTS)/fetch-results.sh $(if $(RUN_ID),--run-id $(RUN_ID),) $(if $(FROM),--from $(FROM),)

# 非 default stack 必须显式确认：并发多套时，打错 STACK 就等于销毁别人的环境。
down:
	@if [ "$(STACK)" != "default" ] && [ "$(CONFIRM)" != "1" ]; then \
	  echo "  ⚠️  当前 STACK=$(STACK) 不是默认 stack。"; \
	  echo "      确认销毁请执行：make down STACK=$(STACK) CONFIRM=1"; \
	  echo "      （先 make fetch STACK=$(STACK) 取回产物，否则数据盘会随实例一起销毁）"; \
	  exit 1; \
	fi
	@$(TF) destroy -auto-approve

# 只删本 stack 的 run 产物，不再 `rm -rf results/*` 通杀 —— 多栈并存时那是灾难。
# run 目录名形如 <track>-<challenge>[-<codec>]-<YYYYmmdd-HHMMSS>，按这个形状匹配，
# 就不会误删别栈的目录，也不会误删 results/_matrix/ 下的矩阵日志与汇总。
clean:
	@echo "  清理 stack=$(STACK) 的本地产物：$(LOCAL_DIR)/"
	@echo "    （其他 stack 目录与 results/_matrix/ 保持不动）"
	@find $(LOCAL_DIR) -maxdepth 1 -mindepth 1 \
	  \( -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' \
	     -o -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz' \) \
	  -exec rm -rf {} + 2>/dev/null || true
	@rm -f $(LOCAL_DIR)/.last-run-id
	@rm -rf $(ROOT)/.build-image-*
	@echo "  ✅ 完成（矩阵日志 results/_matrix/ 未动，要清就手工删）"
