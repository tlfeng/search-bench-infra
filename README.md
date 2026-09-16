# 阿里云 ECS 上的 esrally 自动化压测

用一套代码完成压测的全生命周期：**建网络 → 拉起 ECS → 部署引擎与 esrally → 跑压测 → 结果归档 OSS → 销毁实例**。测试对象是 elasticsearch 与 easysearch 两套引擎、x86 与 ARM 两种架构。

两个核心思路：

- **引擎和 esrally 固化进自定义镜像**——开机后只挂盘、写配置、启动，1~2 分钟进入可压测状态，且每轮环境完全一致；
- **全部按量计费，靠「串行 + 用完即销毁」控制成本**——串行四轮（每轮约 20 小时）每月机时约 700 元，四组常开则要约 4700 元。

新机器从第 1 节开始走；想了解设计取舍直接看第 3、4 节。

---

## 1. 快速开始

### 1.1 前置工具

| 工具 | 用途 | 安装（macOS） |
|---|---|---|
| terraform ≥ 1.5 | 基础设施编排 | `brew install terraform`；brew 版被 macOS 沙箱拦截时，把官方二进制放项目 `bin/` |
| aliyun-cli | 凭据配置、构建镜像 | `brew install aliyun-cli` |
| jq | 凭据注入与自检读 `~/.aliyun/config.json` | `brew install jq` |
| ossutil64 | `make fetch` 拉取结果 | 官网下载放 PATH；没有可先跳过 |
| Docker | `make local-validate` 本地验证脚本 | 可先跳过 |
| SSH 密钥 | 登录实例 | `ssh-keygen -t ed25519` |

### 1.2 创建 RAM 子用户与授权（一次性，控制台操作）

推荐用 RAM 子用户，**不要用主账号 AccessKey**：

1. 打开 <https://ram.console.aliyun.com/users> → **创建用户**；登录名随意（如 `esbench-deploy`），访问方式勾选「**使用永久 AccessKey 访问**」（OpenAPI 调用）；
2. 创建成功后立即下载「创建用户结果」CSV——**AccessKey ID 和 Secret 只显示一次**，先存进密码管理器；CSV 里的控制台登录密码（Password 列）本项目用不到；
3. 给该用户授权以下系统策略：

| 系统策略 | 用途 |
|---|---|
| `AliyunECSFullAccess` | 实例、自定义镜像、安全组、快照、云盘 |
| `AliyunVPCFullAccess` | VPC、vSwitch |
| `AliyunOSSFullAccess` | 结果归档（run-bench 写 OSS）与 `make fetch` 本地拉取（ossutil） |

可选：`AliyunBSSReadOnlyAccess`——只为 `make balance` 查余额账单，不授则该命令不可用。

> 进阶收窄（可选）：嫌 OSS FullAccess 太大，可换成只对压测 bucket 授 `oss:PutObject`/`oss:GetObject` 的自定义策略；若配置 `ram_role_name` 给实例挂角色免 AK 写 OSS，部署用户还需 `ram:PassRole` 权限（简单起见授 `AliyunRAMFullAccess`，或写一条仅允许 Pass 指定角色的自定义策略）。

### 1.3 初始化本机

```bash
# 凭据：交互式输入 AccessKey，只写入 ~/.aliyun/config.json（主目录，仓库之外）
aliyun configure
#    Access Key Id / Secret: 粘贴 1.2 创建的值
#    Default Region Id:      cn-hangzhou（与 tfvars 的 region 一致），其余回车用默认

# 引导：生成 tfvars（自动填公钥/出口 IP）+ 预热 provider + 自检
make setup

# 手工只改一处：oss_bucket（产物归档桶名），其余参数看 example 内注释
$EDITOR terraform/terraform.tfvars
```

`make setup`（`scripts/bootstrap.sh`）做三件事，每件可单独重跑（子命令 `vars` / `providers` / `check`）：

| 步骤 | 做什么 |
|---|---|
| 生成 tfvars | 从 example 复制出 `terraform/terraform.tfvars`，自动填 `public_key`（取 `SSH_PUBKEY` 或 `~/.ssh/*.pub`）和 `operator_cidr`（**直连**探测出口 IP，强制不走代理——代理出口 IP 写进安全组会导致 SSH 连不上） |
| 预热 provider | alicloud provider 下载到 `~/.terraform.d/plugins-mirror`，之后 `terraform init` 完全离线；预热失败不影响，init 自动回退 registry 直连 |
| 自检 | 逐项检查工具/凭据/公钥/tfvars/语料，❌ 项给出现成命令 |

**凭据安全约定**：

- AK 只写入 `~/.aliyun/config.json`，所有脚本经 `scripts/tf-env.sh` 在内存里注入 terraform，不落仓库、不写 tfvars，日志只回显 AK 前 6 位；
- `terraform.tfvars`（含公钥与出口 IP）和 `*.csv` 都被 `.gitignore` 挡住，不会入库；「创建用户结果」CSV 配置完建议删除；
- AK 一旦泄露，去 RAM 控制台禁用/轮换该 AccessKey 即可止损。

### 1.4 首次跑通：调试阶梯

脚本第一次跑大概率要调几轮。按下面的阶梯走，每步只验证一件事，调试总成本可控制在 10 元以内。**推荐全程用 `arm-debug` 档起步**：比 x86 便宜，还能把 aarch64 侧的坑（镜像构建、esrally 依赖、引擎启动）提前暴露——这些问题留到正式轮次才发现代价大得多。

| 阶段 | 做什么 | 成本 | 验证什么 |
|---|---|---|---|
| 0 静态检查 | `make help`；`make -n up PROFILE=arm-debug` | 0 | 命令展开与传参 |
| 1 语料包 | `make corpus` | 0 | 语料可获取（必须做，原因见 3.3） |
| 2 建镜像 | `make image-rally PROFILE=arm-debug WITH_CORPUS=1`<br>`make image-es PROFILE=arm-debug` | 各 ~0.2 元，15~25 分钟 | 网络依赖、语料烘焙与 sha256 校验 |
| 3 起最小环境 | `make up PROFILE=arm-debug`；`make status`；看初始化日志（见 6） | ~0.8 元/时（竞价 ~0.2） | ECS 创建、userdata、引擎健康 |
| 4 秒级一场 | `make bench PROFILE=arm-debug TEST_MODE=1`；`make fetch` | 同上 | 全链路连通：报告生成 + OSS 归档 |
| 5 双节点 | `make down` 后 `make up PROFILE=x86-cheap`；`curl -u admin:Qwer@123 localhost:9200/_cluster/health?pretty` | ~5 元/时 | **必须看到 `number_of_nodes: 2`**——单节点集群也报 green，只看 green 会漏判集群发现问题 |
| 6 正式四轮 | 见 2.3 | — | 出数据 |

构建失败时默认自动清理资源（避免 VPC/实例留在后台计费）；要登进去排查加 `KEEP_ON_FAIL=1`。构建输出的镜像 ID（`m-xxx`）填进 `terraform.tfvars` 对应字段，脚本也会记入 `image-ids.txt`。

---

## 2. 日常使用

### 2.1 档位与架构

两个维度是解耦的：**`PROFILE` 决定 ES 节点的架构与规格；`RALLY_ON` 决定 rally 客户端架构，默认 `arm`**。

rally 只发 HTTP 请求、计算全在服务端，它的架构不影响测量结果；同规格 ARM 比 x86 便宜约 23.5%，所以客户端固定用 ARM，四轮对照还共用同一台，客户端条件反而更一致。唯一前提是 ARM 单核压得满服务端：起压后 `pidstat -p $(pgrep -f esrally) 1`，若服务端还没进平台期、rally 的 %CPU 就逼近 100，说明客户端先饱和，`make up RALLY_ON=x86` 切回。

| PROFILE | ES 节点 | rally | 用途 | 按量/时 | 抢占式/时 |
|---|---|---|---|---|---|
| `debug` | x86 2C8G ×1 | x86 2C8G | x86 链路调试 | 1.05 | 0.21 |
| `arm-debug` | ARM 2C8G ×1 | ARM 2C8G | ARM 链路调试（推荐起步） | 0.80 | 0.18 |
| `x86-cheap` | x86 8C32G ×2 | ARM 4C16G | 双节点验证 | 4.99 | 1.01 |
| `x86-main` | x86 16C64G ×2 | ARM 8C32G | x86 正式档 | 9.97 | 2.01 |
| `arm-cheap` | ARM 8C32G ×2 | ARM 4C16G | ARM 流程验证 | 4.00 | 0.85 |
| `arm-main` | ARM 16C64G ×2 | ARM 8C32G | ARM 正式档 | 8.00 | 1.68 |

价格是 2026-09-16 在 `cn-hangzhou-b` 用 `DescribeSpotPriceHistory` 实测的整套单价合计（2×ES + 1×rally，不含磁盘与流量）。抢占式随行就市（当前约为按量 2 折）且实例可能被回收，**正式出数据的轮次用按量**。

debug 两档是单节点 + 40G 高效云盘：单节点砍掉集群发现这个变量，小盘把存储成本压到忽略不计。机型与镜像是自动配套的——换档位会挑对应架构的镜像，不会出现 ARM 机型配 x86 镜像这种必然失败。

### 2.2 命令速查

| 命令 | 作用 |
|---|---|
| `make setup` | 新机器引导（见 1.3） |
| `make corpus` | 准备语料离线包（本机执行，0 费用） |
| `make balance` | 查账户余额与当月消耗（需 BSS 只读授权） |
| `make validate` / `make plan` | HCL 检查 / 预览将创建的资源（均 0 费用） |
| `make local-validate` | Docker 里验证 install.sh（见 3.6，0 云费用） |
| `make image-es` / `make image-rally` | 构建镜像（一次性，见 3.2） |
| `make up [PROFILE=…] [RALLY_ON=…]` | 拉起环境（内部自动 terraform init/apply） |
| `make status` | 看 IP、target-hosts、当前档位 |
| `make bench [TRACK=geonames] [CHALLENGE=…] [CLIENTS=8] [ENGINE_NAME=es\|ez] [TEST_MODE=1]` | 跑压测 |
| `make fetch [RUN_ID=…]` | 取回产物到 `results/` |
| `make down` | 销毁全部资源 |
| `make ssh-rally` / `ssh-es1` / `ssh-es2` / `tail-rally` | 登录机器 / 看 rally 初始化日志 |

bench 参数的两个坑（geonames track 专属）：

- `CLIENTS=N` 映射的是 `bulk_indexing_clients`（**写入**并发）——track 里没有叫 `clients` 的参数，传错等于没传；
- 搜索任务全部走 esrally 默认并发 1，要测查询吞吐上限必须给 track 打补丁（见第 5 节）。

`TEST_MODE=1` 用极小数据集，秒级完成，只验证链路，结果没有性能意义。

### 2.3 四轮对照与省钱纪律

正式测试矩阵是「ES 架构 × 引擎」，**串行执行——任何时刻只存在一组资源**：

| 轮次 | ES 架构 | 引擎 | user-tags |
|---|---|---|---|
| 1 | x86 | elasticsearch | `arch=x86,engine=es` |
| 2 | x86 | easysearch | `arch=x86,engine=ez` |
| 3 | ARM | elasticsearch | `arch=arm,engine=es` |
| 4 | ARM | easysearch | `arch=arm,engine=ez` |

每轮固定四步：`make up PROFILE=<x86-main|arm-main>` → `make bench TRACK=geonames CLIENTS=8 ENGINE_NAME=<es|ez>` → `make fetch` → `make down`。

成本量级（按上表单价）：四组常开约 4700 元/月（每天 8 小时 × 22 天）；串行每轮约 20 小时、四轮合计约 700 元/月；全部用抢占式能压到约 150 元/月，代价是被回收就整轮重跑。省钱手段的优先级：

1. **串行开机**——省约 7 倍，效果最大；
2. 竞价实例（`use_spot = true`）——调试用，**正式出报告的轮次必须 false**（会被回收）；
3. 降规格——不推荐：内存减半后 page cache 缩到 16G，HNSW 2M 数据集有风险。

换引擎（如 easysearch）：`make image-es PROFILE=x86-main ENGINE=easysearch ES_VER=2.4.0-2969`，把 tfvars 的 `engine` 与镜像 ID 改掉再 `up`。换 ES 架构：直接换 PROFILE，rally 镜像共用，不必重建。

**三条纪律**：

1. 每轮之间必须 `make down`——串行省钱的关键，调试期最容易忘，一晚就是几十块；
2. `make fetch` 在 `make down` 之前，或确认产物已进 OSS——fetch 从 OSS 拉，实例销毁后照样能取；
3. 跑前 `pidstat` 确认 rally 没先饱和——ARM 客户端省钱的前提（见 2.1）。

---

## 3. 工作原理

```
目录结构（省略零散文件）：
├── Makefile                编排入口（setup/corpus/image-*/up/bench/fetch/down）
├── terraform/              VPC/安全组/ECS/云盘
│   └── terraform.tfvars    真实参数，不入库（make setup 生成）
├── scripts/
│   ├── bootstrap.sh        新机器引导（make setup）
│   ├── tf-env.sh           把 ~/.aliyun/config.json 的凭据注入 terraform（仅内存）
│   ├── build-image.sh      起临时实例 → install.sh → 打镜像 → 销毁
│   ├── install.sh          镜像内安装引擎与 esrally
│   ├── prepare-corpus.sh   语料离线包（本机，0 费用）
│   ├── userdata-*.sh.tpl   开机初始化（挂盘/配置/启动）
│   ├── run-bench.sh        触发压测 + 归档 OSS
│   └── fetch-results.sh    拉取产物
├── corpus/                 语料（geonames/ 的 track 定义入库，大文件由 make corpus 生成）
└── bin/                    terraform 官方二进制（不入库）
```

### 3.1 拓扑

```
                阿里云 VPC（单地域单可用区）
  ┌────────────────────────────────────────────────────────────┐
  │  rally 机（ARM，有公网）          ES 节点 × 2（仅内网）      │
  │  ecs.g8y.xlarge 4C16G     或    ecs.g8i.4xlarge x86         │
  │  ecs.g8y.2xlarge 8C32G          ecs.g8y.4xlarge ARM        │
  │  /opt/esrally                   16C64G / ESSD PL1          │
  │        │                         heap 16g × 2              │
  │        └────── 内网 9200 ────────┬────────────┬───────────┤
  │                                  node-1       node-2       │
  └────────────────────────────────────────────────────────────┘
                       └── 结果 tar → OSS（实例销毁后仍在）
```

- **ES 节点不配公网**：减少攻击面，也避免公网带宽干扰 RT 测量，所有运维经 rally 机跳板。安全组只有两条入向规则：SSH 22 对 `operator_cidr`（你的出口 IP），9200-9400 对 VPC 网段——公网上碰不到任何 ES 端口。
- **ES 节点用固定内网 IP**（vSwitch 网段从 `.10` 起顺序分配）：开机前就能算出全量节点列表，直接写进 `discovery.seed_hosts` 与 `initial_master_nodes`，避免「等实例创建后取 IP」在 Terraform 里形成循环依赖。网段 `.10` 被占就改 `main.tf` 里 `locals.es_ips` 的起始偏移。
- **拓扑沿用 geonames 基线**：双节点、每节点 16 vCPU、堆 16g，`search_worker` 合计 50、`write` 合计 32。

### 3.2 镜像：三张，按架构分

ARM 与 x86 二进制不兼容，镜像必须分架构构建；rally 与 ES 软件栈不同，也分开。默认组合（rally 固定 ARM）只需三张：

| 镜像 | 架构 | 何时需要 |
|---|---|---|
| `esbench-es-x86_64` | x86_64 | 测 x86 侧 ES |
| `esbench-es-aarch64` | aarch64 | 测 ARM 侧 ES |
| `esbench-rally-aarch64` | aarch64 | 唯一的 rally 镜像，两套 ES 共用（`RALLY_ON=x86` 才需要 x86 版） |

镜像内已固化：`/opt/es`（引擎）、`/opt/esrally`、es 用户、内核参数（`vm.max_map_count`、关闭 THP）、sysstat。构建用一次性临时便宜机型（2C8G），PROFILE 只决定用哪个：

```bash
make corpus                              # 先有语料包（3.3）
make image-es PROFILE=x86-cheap          # 需要哪套架构建哪张
make image-rally WITH_CORPUS=1           # rally 默认 ARM
# make image-all 一次建两张，但两个 PROFILE 都跑会重复构建 rally，建议分开跑
```

系统盘固定 40G：OS + 引擎 + 语料足够，ESSD 系统盘与数据盘同价，盘小镜像的快照存储费也同步下降；数据一律放数据盘 `/data`。

### 3.3 语料离线烘焙（国内必踩的坑）

esrally 取语料的两条网络路径，在国内 ECS 上大概率都走不通：

| 内容 | 默认来源 | 问题 |
|---|---|---|
| track 定义 | github.com/elastic/rally-tracks | 拉取不稳定 |
| 语料数据 | rally-tracks.elastic.co | 实测由 Google Cloud Storage 托管，基本不可达 |

任一失败，`esrally race` 直接起不来或长时间卡在下载。所以先把 track + 语料打成离线包、构建镜像时烘焙进去，运行期 esrally 完全不碰外网（这就是 1.4 阶段 1 和 `WITH_CORPUS=1` 必须做的原因）：

`prepare-corpus.sh` 的行为：track 定义优先复用本地 `corpus/geonames/`（保证与历史基线同版本，新老数据才可比）；语料按 `track.json` 声明的 `source-file` 下载，已存在则跳过；生成 sha256 清单，构建时逐条校验，**任一不符构建即失败**，不会留下语料损坏的镜像。语料 252MB，烘进镜像后镜像约增大 250MB，快照存储约 0.03 元/月，可忽略。

烘焙位置是 `/opt/rally-corpus`，**不能放 `/data`**——运行期数据盘会挂到 `/data`，把镜像里的内容遮住。开机后 userdata 把它复制到 `/data/rally/benchmarks/`（`~/.rally` 已软链过去）。`run-bench.sh` 会自动探测已铺设的 track 并改用 `--track-path`（不联网），找不到才回退 `--track=` 并打印明确告警。

### 3.4 操作系统：Alibaba Cloud Linux 4

镜像正则 `^aliyun_4_(x64|arm64)_20G_alibase_[0-9]{8}[.]vhd$`（`--base-image-regex` 可覆盖）。必须第 4 代的原因：

| 世代 | 系统 Python | 能否装 esrally 2.12.0（`requires-python >= 3.9`） |
|---|---|---|
| Alinux 3（Anolis 8 上游） | 3.6.8 | ❌ `pip install` 被 Requires-Python 直接挡下 |
| Alinux 4（Anolis 23 上游） | 3.10 | ✅ 开箱可用；内核更新，且对神龙/CIPU 与 ESSD 有针对性优化 |

镜像名的三个坑（都用 `DescribeImages` 实测过）：版本号里**没有** `2104`；架构写作 `x64`/`arm64`，**没有** `_64` 字面串；必须加 `[0-9]{8}[.]vhd$` 尾巴排除 AI 增强版等变体。若手动换回老世代，`install.sh` 会尝试 `dnf module install python39` 兜底，找不到才报错退出——不会静默失败。

Rocky Linux 9 也能用，`install.sh` 对它做了三件必需处理：`dnf install python3-devel gcc`（esrally 的 C 扩展编译）、关 firewalld（云上已有安全组，主机层防火墙对压测只有干扰）、SELinux 调 permissive（enforcing 下 `/opt`、`/data` 的上下文不对会导致启动失败）。

### 3.5 换引擎：easysearch 的安装细节

```bash
make image-es PROFILE=x86-cheap ENGINE=easysearch ES_VER=2.4.0-2969
```

- 发布地址规律（已实测 HTTP 200）：`https://release.infinilabs.com/easysearch/<channel>/[bundle/]easysearch-<版本>-linux-<amd64|arm64>.tar.gz`，脚本自动下载并校验 `.sha512`；
- 架构映射：`x86_64 → amd64`，`aarch64 → arm64`；
- 默认用 snapshot 下的 **bundle 包**（自带 JDK）：`initialize.sh` 检测到 `$ES_HOME/jdk` 就不再外网现拉 200MB 的 JDK21；它仍负责生成证书与写入 admin 密码，脚本已加 3 次重试抗网络抖动；
- 内部定制包用 `--es-pkg-url` 覆盖下载地址。

### 3.6 本地容器验证：把建镜像的坑免费踩完

建一次镜像要起临时实例（~0.2 元 + 15~25 分钟），而安装脚本第一次跑必然要改几轮。先在本地 Docker 里把 `install.sh` 验掉，云上那一轮大概率一次过：

```bash
make local-validate ROLE=all                        # 两个角色都验
make local-validate ROLE=rally WITH_CORPUS=1        # 含语料烘焙与 sha256 校验
make local-validate ROLE=es ENGINE=easysearch ES_VER=2.4.0-2963
```

容器用 `linux/arm64`（Apple Silicon 原生，与阿里云 ARM 同架构）；基础镜像 `openanolis/anolisos:23` 是 Alinux 4 的上游（Python 3.10 + dnf），与目标环境最接近。需要 Docker Desktop 在运行，首次拉基础镜像约 200MB。

这套验证实际抓到过 8 个问题，都只在真跑时才暴露：

| # | 问题 | 修法 |
|---|---|---|
| 1 | Alinux 3 系统 Python 只有 3.6，esrally 装不上 | 直接改用 Alinux 4（3.4） |
| 2 | `curl` 与镜像自带 `curl-minimal` 冲突，整条 dnf 事务回滚，还被 `|| true` 掩盖成静默成功 | 逐包安装，单个冲突不影响其他包 |
| 3 | `/etc/sysctl.d` 目录不存在，`set -e` 中断整个安装 | 先建目录 |
| 4 | easysearch 的 sha512 校验形同虚设（包被改名后永远找不到文件） | 校验做成失败即中止 |
| 5 | easysearch 的 tar 包没有顶层目录，按名字 `find` 必为空 | 解到专属临时目录，按顶层布局自适应两种包 |
| 6 | easysearch 不含 JDK、没有离线建号工具 | 走官方 `initialize.sh -s` + 3 次重试 |
| 7 | easysearch 密码策略要求 ≥9 位，`Qwer@123` 会被拒 | EZ 侧用 `Qwer@1234`，由 `ENGINE_PASS` 统一派生 |
| 8 | 关 TLS 的键名写成 xpack 风格，等于没改，rally 连不上 | 正确是 `security.ssl.http.enabled` |

---

## 4. 设计决策一览

正文解释过的不重复，这里只收一句话理由：

| 决策 | 理由 |
|---|---|
| Terraform 而非 ROS | provider 成熟、可跨云迁移，`.tf` 即文档 |
| 引擎固化进镜像 | 开机 1~2 分钟可用；每轮环境逐字节一致，基准才可比 |
| 镜像按架构分、默认三张 | ARM/x86 二进制不兼容；rally 固定 ARM 后两套 ES 共用一张客户端镜像 |
| 双节点 | 与基线拓扑一致；query phase parallelism 需要足够的 `search_worker` 线程，单节点 16 核只有 25 条线程，会低估引擎差距 |
| 堆固定 16g | 与基线一致；GC 停顿更短、p99 更稳；64G 机器余约 48G 给 page cache |
| 数据盘 ESSD PL1（Makefile 按档位给 100G） | PL1 的 350MB/s 低于各档实例带宽上限，永不触发突发回落，速度恒定才可比；geonames 2.8G + merge 峰值 <10G + HNSW 3.9G，不够可在线扩容 |
| 报告文件名带时间戳 | esrally 对已存在的 markdown 报告是**追加**不是覆盖，重名会混入两场数据 |
| 结果写 OSS 而非留在实例 | 实例随时销毁，OSS 才持久；`fetch` 从 OSS 拉 |

## 5. 已知限制与注意事项

1. **认证账号是 `admin`，两个引擎密码不同**：elasticsearch → `Qwer@123`（用 `elasticsearch-users` 离线写入 file realm）；easysearch → `Qwer@1234`（它的密码策略硬性要求 ≥9 位，`Qwer@123` 会被拒）。两个值都由 Makefile 的 `ENGINE_PASS` 按引擎派生，镜像构建与开机健康检查同源，不会不一致。**对外交付前务必改掉默认密码。**
2. **查询侧并发需要改 track**：geonames 的 `challenges/default.json` 里并发参数只有 `bulk_indexing_clients`（写入侧），搜索任务（`term`/`default`/`phrase`/`scroll`）没有 `clients`、走 esrally 默认 1——这正是历史 race「latency == service time、零排队」的原因。要测查询吞吐上限，另存一份给搜索任务加了 `"clients": ...` 的 track 专用于爬坡，**保留原始 track 不动**才能与基线可比。
3. **segment 数要用 `GET /_cat/segments/<索引>`**，不要用 `_all`——easysearch 的 `_all` 会计入 `.security` 索引。
4. **`perf-env-guard` 未接入**：`../04-性能测试-esrally/perf-env-guard/` 的指纹与绑核能力建议集成进 `run-bench.sh` 的起跑前校验；当前只采集最简指纹（CPU 型号/核数/内存/governor/THP）。

## 6. 排查对照表

| 现象 | 大概率原因 | 怎么查 |
|---|---|---|
| `terraform apply` 报缺镜像 ID | 镜像没建或架构填错 | 报错会点名该填哪个字段、先跑哪条命令 |
| SSH 连不上新实例 | `operator_cidr` 没放行你的出口 IP | 查安全组规则；`curl -4 ifconfig.me` 取真实 IP，IP 变了改 tfvars 重新 apply |
| 实例起来了但 ES 没起 | userdata 失败 | `make ssh-es1 'cat /var/log/es-init.log'` |
| 集群只有一个节点 | seed_hosts / 固定 IP 未生效 | `curl localhost:9200/_cat/nodes?v`；核对 vSwitch 网段 `.10` 是否被占用 |
| rally 连不上 ES | 安全组或凭证不对 | `make ssh-rally 'cat /etc/es-targets.conf'`；rally 机上 curl 一下 9200 |
| bench 卡在下载 / 找不到 track | 镜像没烘焙语料 | `WITH_CORPUS=1` 重建 rally 镜像；`make ssh-rally 'ls /data/rally/benchmarks/tracks/'` |
| bench 报 report 文件已存在 | 报告名重复（esrally 追加不覆盖） | 脚本已带时间戳；手改过文件名需注意 |
| 产物取不到 | fetch 时实例已销毁且 OSS 没写成功 | 检查 `ossutil64` 配置与实例 RAM 角色权限 |
