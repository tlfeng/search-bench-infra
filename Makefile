SHELL   := /bin/bash
ROOT    := $(shell pwd)
TF      := $(ROOT)/terraform
SCRIPTS := $(ROOT)/scripts

# 凭据注入脚本：从 ~/.aliyun/config.json 读 AK/SK 与 TF_CLI_CONFIG_FILE，
# 只存在于当前 shell 内存（不写 tfvars、不落盘）。所有云操作目标都要 source 它。
TFENV   := $(SCRIPTS)/tf-env.sh

# 优先用项目内 bin/terraform（官方二进制，不污染系统），否则退回 PATH 里的
TERRAFORM ?= $(if $(wildcard $(ROOT)/bin/terraform),$(ROOT)/bin/terraform,terraform)

# build-image.sh / fetch-results.sh 会直接调用 terraform 与 aliyun CLI，
# 因此把它们的目录显式注入 PATH（沙箱默认 PATH 里没有 /opt/homebrew/bin）。
export PATH := $(dir $(TERRAFORM)):/opt/homebrew/bin:$(HOME)/.local/bin:$(PATH)

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

# rally 客户端架构，独立于 ES：默认 arm（同规格比 x86 便宜约 23.5%）。
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
# LOCAL_DIR=<路径>                仅 fetch 时用，默认 results/
TRACK ?=
CHALLENGE ?=
CLIENTS ?=
ENGINE_NAME ?=
RUN_ID ?=

# ---------- 引擎 ----------
ENGINE ?= elasticsearch
# 注意：easysearch 的密码策略要求 >=9 位（Qwer@123 只有 8 位会被拒），
# 所以 EZ 与 ES 的密码不同。镜像构建（--es-pass）与开机（tfvars es_password）
# 都用下面同一个变量，保证两边一致。
ES_PASS ?= Qwer@123
EZ_PASS ?= Qwer@1234
ENGINE_PASS := $(if $(filter easysearch,$(ENGINE)),$(EZ_PASS),$(ES_PASS))

# 系统盘 40G 足够（OS+引擎+语料/JDK）；ESSD 系统盘与数据盘同价，
# 盘小自定义镜像的快照存储费也同步下降。数据一律放数据盘 /data。
SYSTEM_DISK_SIZE := 40

# 版本：ES 与 easysearch 各自的默认值
ES_VER ?= 8.19.20
# easysearch 用 snapshot/bundle 的 2.4.0-2969：发布包本体不含 JDK，
# bundle 自带 JDK，省去 initialize.sh 现拉 ~200MB（慢且依赖外网）。
EZ_VER ?= 2.4.0-2969
ENGINE_VER := $(if $(filter easysearch,$(ENGINE)),$(EZ_VER),$(ES_VER))
# bundle 包只在 snapshot/bundle/ 路径下
EZ_CHANNEL ?= snapshot
EZ_BUNDLE  ?= 1
EZ_VER ?= 2.4.0-2969
ES_VER ?=                     # 留空按引擎取默认：es=8.19.20 / easysearch=2.4.0-2963
BASE_IMG ?=                   # 基础镜像正则，留空用默认 ^aliyun_4_(x64|arm64)_20G_alibase_[0-9]{8}[.]vhd$；需要 Rocky 时传 '^rockylinux_9'

.PHONY: help init validate fmt plan corpus balance local-validate setup image-all image-es image-rally up status \
        ssh-rally ssh-es1 ssh-es2 bench fetch down clean tail-rally

help:
	@echo "search-bench-infra —— 搜索引擎压测基础设施（esrally on 阿里云 ECS，Terraform 自动化）"
	@echo
	@echo "档位（PROFILE，当前默认 $(PROFILE)）—— 只决定 ES 节点的架构与规格："
	@echo "  debug       x86 2C8G  x1 节点 <- 从这开始，整套约 1 元/小时"
	@echo "  arm-debug   ARM 2C8G  x1 节点 <- 更便宜（0.8 元/时），且能提前暴露 aarch64 兼容性问题"
	@echo "  x86-cheap   x86 8C32G        <- 再验证「双节点集群发现」"
	@echo "  x86-main    x86 16C64G       <- 主力档，与基线算力对齐"
	@echo "  arm-cheap   ARM 8C32G"
	@echo "  arm-main    ARM 16C64G"
	@echo
	@echo "rally 客户端架构（RALLY_ON，当前默认 $(RALLY_ON)）—— 独立于 ES："
	@echo "  arm   ARM 4C16G/8C32G，比同规格 x86 便宜约 23.5%（默认）"
	@echo "  x86   若实测 ARM 单核压不满服务端，改回这个"
	@echo
	@echo "首次使用（0 费用 -> 最省）："
	@echo "  make setup                    新机器引导：生成 tfvars + 预热 provider + 自检（凭据先手动 aliyun configure）"
	@echo "  make corpus                   准备语料离线包（本机执行，不产生云费用）"
	@echo "  make balance                  查账户余额与当月消耗（需 BSS 只读权限）"
	@echo "  make local-validate ROLE=all  用 Docker 在本地验证 install.sh（0 云费用）"
	@echo "  make image-rally WITH_CORPUS=1  建带语料的 rally 镜像（必须带，否则国内拉不到语料）"
	@echo "  make image-es  PROFILE=arm-debug"
	@echo
	@echo "常用："
	@echo "  make up                       按档位创建 ECS（ES + rally）"
	@echo "  make bench TRACK=geonames CLIENTS=8"
	@echo "  make bench TEST_MODE=1        极小数据集，秒级完成，只用于打通链路"
	@echo "  make fetch                    取回产物到 results/"
	@echo "  make down                     销毁全部资源（省钱）"
	@echo
	@echo "排查（都不产生费用）："
	@echo "  make validate                 HCL 语法检查"
	@echo "  make plan                     预览将要创建的资源"
	@echo "  make status                   查看 IP、target-hosts、当前档位"
	@echo "  make ssh-rally / ssh-es1      直接登录"
	@echo "  make tail-rally               看 rally 机初始化日志"
	@echo
	@echo "推荐推进顺序："
	@echo "  1) make corpus"
	@echo "     make image-rally PROFILE=arm-debug WITH_CORPUS=1"
	@echo "     make image-es    PROFILE=arm-debug"
	@echo "  2) make up PROFILE=arm-debug && make bench TEST_MODE=1 && make down"
	@echo "  3) make up PROFILE=x86-cheap    验证双节点集群发现（必须 number_of_nodes=2）"
	@echo "  4) 四轮对照：x86/ARM × EZ/ES，每轮之间务必 make down"
init:
	# init 也要注入 TF_CLI_CONFIG_FILE（本地 provider 镜像），否则会去查 registry，
	# 国内网络一抖就失败；-upgrade 会强制查版本，去掉（lock 文件已锁版本）。
	cd $(TF) && . $(TFENV) && $(TERRAFORM) init

validate: init
	cd $(TF) && $(TERRAFORM) validate
	@echo "  ✅ HCL 语法与引用校验通过（未创建任何资源，0 元）"

fmt:
	cd $(TF) && $(TERRAFORM) fmt -recursive

plan: init
	cd $(TF) && . $(TFENV) && $(TERRAFORM) plan \
	  -var="profile=$(PROFILE)" \
	  -var="rally_arch=$(RALLY_ON)" \
	  -var="engine=$(ENGINE)" \
	  -var="es_password=$(ENGINE_PASS)" \
	  -var="es_node_count=$(ES_NODES)" \
	  -var="es_data_disk_category=$(ES_DISK_CAT)" \
	  -var="es_data_disk_size=$(ES_DISK_SIZE)" \
	  -var="rally_data_disk_category=$(RALLY_DISK_CAT)" \
	  -var="rally_data_disk_size=$(RALLY_DISK_SIZE)" \
	  -var="system_disk_size=$(SYSTEM_DISK_SIZE)"

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
# geonames 的并发参数叫 bulk_indexing_clients，不是 clients；传错等于没传
ifneq ($(strip $(CLIENTS)),)
BENCH_ARGS += --clients $(CLIENTS) --clients-param $(or $(CLIENTS_PARAM),bulk_indexing_clients)
endif
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

up: init
	cd $(TF) && . $(TFENV) && $(TERRAFORM) apply -auto-approve \
	  -var="profile=$(PROFILE)" \
	  -var="rally_arch=$(RALLY_ON)" \
	  -var="engine=$(ENGINE)" \
	  -var="es_password=$(ENGINE_PASS)" \
	  -var="es_node_count=$(ES_NODES)" \
	  -var="es_data_disk_category=$(ES_DISK_CAT)" \
	  -var="es_data_disk_size=$(ES_DISK_SIZE)" \
	  -var="rally_data_disk_category=$(RALLY_DISK_CAT)" \
	  -var="rally_data_disk_size=$(RALLY_DISK_SIZE)" \
	  -var="system_disk_size=$(SYSTEM_DISK_SIZE)"
	@$(MAKE) --no-print-directory status

status:
	@cd $(TF) && . $(TFENV) && $(TERRAFORM) output

ssh-rally:
	@ssh -o StrictHostKeyChecking=no root@$$(cd $(TF) && $(TERRAFORM) output -raw rally_public_ip)

ssh-es1:
	@ssh -o StrictHostKeyChecking=no root@$$(cd $(TF) && $(TERRAFORM) output -json es_public_ips | tr -d '[]" ' | cut -d, -f1)

ssh-es2:
	@ssh -o StrictHostKeyChecking=no root@$$(cd $(TF) && $(TERRAFORM) output -json es_public_ips | tr -d '[]" ' | cut -d, -f2)

tail-rally:
	@ssh -o StrictHostKeyChecking=no root@$$(cd $(TF) && $(TERRAFORM) output -raw rally_public_ip) 'tail -50 /var/log/rally-init.log'

bench:
	$(SCRIPTS)/run-bench.sh $(BENCH_ARGS)

fetch:
	$(SCRIPTS)/fetch-results.sh $(if $(RUN_ID),--run-id $(RUN_ID),)

down:
	cd $(TF) && . $(TFENV) && $(TERRAFORM) destroy -auto-approve

clean:
	rm -rf $(ROOT)/results/* $(ROOT)/.build-image-*
