# 阿里云 ECS 上的 esrally 自动化压测

用一套代码跑完压测全生命周期：**建网络 → 拉起 ECS → 部署引擎与 esrally → 压测 → 归档结果 → 销毁实例**。被测对象是 elasticsearch 与 easysearch，覆盖 x86 与 ARM 两种架构。

两个核心做法：

- **引擎与 esrally 固化进自定义镜像**——开机只挂盘、写配置、启动，1~2 分钟进入可压测状态，且每轮环境一致、结果可比；
- **全按量计费 + 串行 + 用完即销毁**——单轮按 2 小时计，跑完立刻 `make down`，价格见 2.2（调试轮次可切竞价，见 2.4）。

适用场景：需要在**国内网络**下以**可复现的方式**对比 elasticsearch / easysearch 在不同架构与规格上的写入与查询性能，且环境要随时可建可拆。

---

## 1. 快速开始

### 1.1 前置工具

| 工具 | 用途 | 安装（macOS） |
|---|---|---|
| terraform ≥ 1.5 | 基础设施编排 | `brew install terraform`；brew 版被 macOS 沙箱拦截时，把官方二进制放项目 `bin/` |
| aliyun-cli | 配置凭据、构建镜像 | `brew install aliyun-cli` |
| jq | 凭据注入与自检读 `~/.aliyun/config.json` | `brew install jq` |
| ossutil64 | `make fetch` 从 OSS 拉结果（可选，见 1.6） | 官网下载后放 PATH |
| Docker | `make local-validate`（可选，见 3.6） | Docker Desktop |
| SSH 密钥 | 登录实例 | `ssh-keygen -t ed25519` |

### 1.2 创建 RAM 用户并授权（一次性，控制台操作）

不要用主账号 AccessKey。

1. 打开 <https://ram.console.aliyun.com/users> → **创建用户**，登录名随意（如 `esbench-deploy`），访问方式勾选「**使用永久 AccessKey 访问**」；
2. 创建后立即下载「创建用户结果」CSV——**AccessKey Secret 只显示一次**，存进密码管理器后把 CSV 删掉（里面的控制台登录密码本项目用不到）；
3. 给该用户授予系统策略：

| 系统策略 | 用途 |
|---|---|
| `AliyunECSFullAccess` | 实例、自定义镜像、安全组、快照、云盘 |
| `AliyunVPCFullAccess` | VPC、vSwitch |
| `AliyunOSSFullAccess` | 结果归档与拉取 |
| `AliyunBSSReadOnlyAccess`（可选） | 仅供 `make balance` 查余额与账单，不授则该命令不可用 |

> 想收窄权限：OSS 可换成只对结果桶授 `oss:PutObject` / `oss:GetObject` 的自定义策略；若给实例配 `ram_role_name` 免 AK 写 OSS，部署用户还需 `ram:PassRole` 权限。

### 1.3 初始化本机

```bash
aliyun configure                    # 粘贴 1.2 的 AK/SK；Region 填 cn-hangzhou（与 tfvars 一致）
make setup                          # 生成 tfvars + 预热 provider + 自检
$EDITOR terraform/terraform.tfvars  # 手工只需改 oss_bucket，其余看文件内注释
```

`make setup` 即 `scripts/bootstrap.sh`，三件事可单独重跑（子命令 `vars` / `providers` / `check`）：

| 步骤 | 做什么 |
|---|---|
| 生成 tfvars | 从 example 复制出 `terraform/terraform.tfvars`，自动填 `public_key`（取 `SSH_PUBKEY` 或 `~/.ssh/*.pub`）和 `operator_cidr`（**直连**探测出口 IP——走代理会把代理 IP 写进安全组，SSH 就连不上了） |
| 预热 provider | 把 alicloud provider 下到 `~/.terraform.d/plugins-mirror`，之后 `terraform init` 可离线；预热失败不影响，init 自动回退 registry 直连 |
| 自检 | 逐项检查工具/凭据/公钥/tfvars/语料，失败项给出现成命令 |

凭据只走内存：AK 写入 `~/.aliyun/config.json`，由 `scripts/tf-env.sh` 注入 terraform，不落仓库、不写 tfvars，日志只回显 AK 前 6 位；`terraform.tfvars`（含公钥与出口 IP）与 `*.csv` 都被 `.gitignore` 挡住。AK 若泄露，去 RAM 控制台禁用/轮换该 AccessKey 止损。

### 1.4 准备语料（本机执行，0 云费用）

```bash
make corpus        # 产出 corpus/geonames-corpus.tar.gz 与 .sha256
```

**新克隆的仓库必须先跑这一步**——语料 253MB，未入库（见 3.3 说明为什么必须离线打包）。若下载失败（国内直连 GCS 可能不通），手动取 `documents-2.json.bz2` 放进 `corpus/geonames-data/` 再跑一次即可：脚本本地优先、已存在则跳过。

### 1.5 构建镜像（一次性）

```bash
make image-rally WITH_CORPUS=1     # rally 客户端镜像；WITH_CORPUS=1 必须有，否则运行期拉不到语料
make image-es PROFILE=arm-debug    # ES 镜像：PROFILE 只决定架构，x86 侧换 PROFILE=x86-main 再建一张
```

- 各约 0.2 元、15~25 分钟，用一次性的 2C8G 临时实例构建，`PROFILE` 只决定架构；
- **同名镜像会自动跳过构建**，反复执行不会重复花钱；要强制重建 `FORCE=1 make image-es`；
- 构建失败默认自动清理临时资源；要登进去排查用 `KEEP_ON_FAIL=1 make image-es`；
- 成功后会打印镜像 ID 并记入台账 `image-ids.txt`，用 `make image-ls` 查看、`make image-use` 切换 tfvars 指向。

### 1.6 跑一轮

```bash
make up PROFILE=arm-debug            # 起环境（内部自动 terraform init/apply）
make status                          # 看 IP、target-hosts、档位与计费方式
make bench TRACK=geonames CLIENTS=8  # 跑压测；先加 TEST_MODE=1 试链路
make fetch                           # 取产物到 results/
make down                            # 销毁全部资源
```

`make fetch` 默认从 OSS 拉，**实例销毁后照样能取**；本机没装 `ossutil64` 时自动改用 scp，那时实例必须还在——所以 fetch 要放在 down 之前。想强制走 scp：`make fetch FROM=instance`。

### 1.7 首次跑通：验证阶梯

脚本第一次跑大概率要调几轮。按下面顺序走，每步只验证一件事，总成本可控制在 10 元内。**建议全程用 `arm-debug` 起步**：比 x86 便宜，还能把 aarch64 侧的坑（镜像构建、esrally 依赖、引擎启动）提前暴露，而不是留到正式轮次才发现。

| 步骤 | 命令 | 成本 | 验证点 |
|---|---|---|---|
| 0 静态检查 | `make help`；`make -n up PROFILE=arm-debug` | 0 | 命令展开与传参 |
| 1 语料 | `make corpus` | 0 | 语料可获取 |
| 2 镜像 | `make image-rally WITH_CORPUS=1`<br>`make image-es PROFILE=arm-debug` | 各 ~0.2 元 | 网络依赖、语料烘焙与 sha256 校验 |
| 3 起最小环境 | `make up PROFILE=arm-debug`；`make status`；`make tail-rally` | 约 1.1 元/时（竞价 0.5） | ECS 创建、userdata、引擎健康 |
| 4 秒级一场 | `make bench PROFILE=arm-debug TEST_MODE=1`；`make fetch` | 同上 | 全链路连通：报告生成 + 归档 |
| 5 双节点 | `make down` 后 `make up PROFILE=x86-cheap`，再 `curl -u admin:<默认口令见第 4 节> localhost:9200/_cluster/health?pretty` | 约 5.8 元/时（竞价 1.8） | **必须看到 `number_of_nodes: 2`**——单节点集群也报 green，只看 green 会漏判集群发现问题 |
| 6 正式轮次 | 见 2.5 | — | 出数据 |

---

## 2. 参考

### 2.1 档位与全局参数

两个维度是解耦的：**`PROFILE` 决定 ES 节点的架构与规格；`RALLY_ON` 决定客户端架构（默认 `arm`）**。ES 节点数默认跟随档位，可用 `ES_NODES=<n>` 覆盖。

| PROFILE | ES 节点 | rally | 用途 |
|---|---|---|---|
| `debug` | x86 2C8G ×1 | x86 2C8G | x86 链路调试 |
| `arm-debug` | ARM 2C8G ×1 | ARM 2C8G | ARM 链路调试（推荐起步） |
| `x86-cheap` | x86 8C32G ×2 | ARM 4C16G | 双节点验证 |
| `arm-cheap` | ARM 8C32G ×2 | ARM 4C16G | ARM 流程验证 |
| `x86-main` | x86 16C64G ×2 | ARM 8C32G | x86 正式档 |
| `arm-main` | ARM 16C64G ×2 | ARM 8C32G | ARM 正式档 |

机型与镜像是自动配套的——换档位会挑对应架构的镜像，不会出现 ARM 机型配 x86 镜像这种必然失败。debug 两档是单节点 + 40G ESSD：单节点砍掉集群发现这个变量，小盘把存储成本压到可忽略。

rally 固定用 ARM：它只发 HTTP 请求、计算都在服务端，架构不影响测量结果，而同规格 ARM 比 x86 便宜约 23.5%。唯一前提是单核压得满服务端——起压后用 `pidstat -p $(pgrep -f esrally) 1` 看，若服务端还没进平台期、rally 的 %CPU 就逼近 100，说明客户端先饱和，`make up RALLY_ON=x86` 切回。

### 2.2 成本

单价（含该机的 40G 系统盘与数据盘，2026-09 在 `cn-hangzhou` 实测）：

| 角色 | 机型 | 数据盘 | 按量/时 | 竞价/时 |
|---|---|---|---|---|
| ES／rally | x86 2C8G `ecs.g8i.large` | 40G | 0.69 | 0.27 |
| ES／rally | ARM 2C8G `ecs.g8y.large` | 40G | 0.57 | 0.26 |
| ES | x86 8C32G `ecs.g8i.2xlarge` | 100G | 2.39 | 0.71 |
| ES | ARM 8C32G `ecs.g8y.2xlarge` | 100G | 1.89 | 0.63 |
| ES | x86 16C64G `ecs.g8i.4xlarge` | 100G | 4.48 | 1.13 |
| ES | ARM 16C64G `ecs.g8y.4xlarge` | 100G | 3.49 | 0.97 |
| rally | ARM 4C16G `ecs.g8y.xlarge` | 40G | 0.97 | 0.34 |
| rally | ARM 8C32G `ecs.g8y.2xlarge` | 40G | 1.77 | 0.50 |

单轮价格 = **(节点数 × ES 单价 + rally 单价) × 轮次小时数**，轮次按 **2 小时计**（含开机、一次压测、取产物与销毁的余量）。

**单轮价格（按量，元）**：

| ES 机型 | 1 节点 | 2 节点 | 3 节点 | 4 节点 |
|---|---|---|---|---|
| x86 2C8G | 2.8 | 4.1 | 5.5 | 6.9 |
| ARM 2C8G | 2.3 | 3.4 | 4.5 | 5.7 |
| x86 8C32G | 6.7 | 11.5 | 16.3 | 21.0 |
| ARM 8C32G | 5.7 | 9.5 | 13.3 | 17.1 |
| x86 16C64G | 12.5 | 21.5 | 30.4 | 39.4 |
| ARM 16C64G | 10.5 | 17.5 | 24.5 | 31.5 |

**单轮价格（竞价，元）**：

| ES 机型 | 1 节点 | 2 节点 | 3 节点 | 4 节点 |
|---|---|---|---|---|
| x86 2C8G | 1.1 | 1.6 | 2.2 | 2.7 |
| ARM 2C8G | 1.0 | 1.5 | 2.0 | 2.6 |
| x86 8C32G | 2.1 | 3.5 | 5.0 | 6.4 |
| ARM 8C32G | 1.9 | 3.2 | 4.5 | 5.7 |
| x86 16C64G | 3.3 | 5.5 | 7.8 | 10.1 |
| ARM 16C64G | 2.9 | 4.9 | 6.8 | 8.7 |

读表前先知道三件事：

- **单价已含全部磁盘**，不用另加。ESSD PL1 云盘 0.0021 元/GiB/时，系统盘与数据盘同价；磁盘在单价里的占比随规格下降（2C8G 档约 24%，16C64G 档约 7%）。
- **竞价只对算力打折**，磁盘按原价计，所以整套的竞价/按量比在 0.25~0.40 之间浮动，不是固定折扣。切换方式见 2.4。
- 出网流量 0.8 元/GB，且**只对出方向收费**；压测以入方向（下载语料、提交请求）为主，入方向免费，量级远小于主机。

一轮要跑多个 track、或加重复次数取中位数时，用上面的每小时单价乘实际机时即可。想缩短单轮，可以用不跑查询的 `append-no-conflicts-index-only`（track 自带，用法 `make bench CHALLENGE=append-no-conflicts-index-only`）——省掉全部查询任务后，轮次时长主要就剩写入与 force-merge。

**实例销毁后仍在计费的只有存储**：

| 计费项 | 说明 | 单价 | 量级 |
|---|---|---|---|
| 自定义镜像底层快照 | 与实例是否运行无关 | 0.12 元/GB/月 | 每个镜像约 1 元/月 |
| 云盘 | 随实例销毁；运行期已计入上表 | 0.0021 元/GiB/时 | — |
| OSS 结果归档 | 需账号已开通 OSS（未开通时 `aliyun oss ls` 返回 `UserDisable`） | 按 OSS 存储计费 | 视归档量 |

快照按**实占**而非源盘容量计费（40G 系统盘建出来的镜像通常只占几个 GB，实占可用 `DescribeSnapshots` 的 `FullSnapshotSizeInBytes` 查）。每个镜像月费约 1 元，低于重建一次要花的 15~25 分钟机时，所以值得常留。

核对实际花费用 `make balance`（需 BSS 只读授权，纯查询）：分产品栏会把「云服务器 ECS」与「块存储」分开列，可直接验证主机与存储各占多少。另注意按量付费要求余额达到门槛（通常 100 元），不足时 `CreateInstance` 报 `InvalidAccountStatus.NotEnoughBalance`（403）。

### 2.3 命令速查

`make help` 是权威列表；常用命令与关键参数：

| 命令 | 作用 |
|---|---|
| `make setup` | 新机器引导（见 1.3） |
| `make corpus` | 语料离线包（本机，0 费用） |
| `make validate` / `make plan` | HCL 检查 / 预览将创建的资源（均 0 费用） |
| `make local-validate` | Docker 里验证 install.sh（见 3.6，0 云费用） |
| `make image-es` / `make image-rally` / `make image-all` | 构建镜像（见 1.5） |
| `make image-ls` / `make image-use` | 镜像台账 / 切换 tfvars 指向（见 2.7） |
| `make up [PROFILE=…] [RALLY_ON=…] [ES_NODES=…] [USE_SPOT=1]` | 拉起环境 |
| `make status` | IP、target-hosts、当前档位与计费方式（`billing`） |
| `make bench [TRACK=…] [CHALLENGE=…] [CLIENTS=…] [ENGINE_NAME=es\|ez] [TEST_MODE=1]` | 跑压测 |
| `make fetch [RUN_ID=…] [FROM=instance]` | 取回产物到 `results/` |
| `make down` | 销毁全部资源 |
| `make ssh-rally` / `ssh-es1` / `ssh-es2` / `tail-rally` | 登录机器 / 看 rally 初始化日志 |
| `make balance` | 账户余额与当月消耗（需 BSS 只读授权） |

bench 的两个坑（geonames track 专属）：

- `CLIENTS=N` 映射的是 `bulk_indexing_clients`（**写入**并发）——track 里没有叫 `clients` 的参数，传错等于没传；
- 搜索任务全部走 esrally 默认并发 1，要测查询吞吐上限必须给 track 打补丁（见第 4 节第 2 条）。

`TEST_MODE=1` 用极小数据集，秒级完成，只验证链路，结果没有性能意义。

### 2.4 计费切换（按量 / 竞价）

三档开关，三个都不传就沿用 `terraform.tfvars` 里的值：

| 目标 | 命令 |
|---|---|
| 整套按量（正式出数据） | `make up`（tfvars 里 `use_spot = false`） |
| 整套竞价（便宜但可能被回收） | `make up USE_SPOT=1` |
| ES 按量 + rally 竞价（推荐） | `make up SPOT_RALLY=1` |
| 由 tfvars 决定 | 三个都不传 |

优先级：`SPOT_ES` / `SPOT_RALLY` > `USE_SPOT` > tfvars 里的 `use_spot`。取值 `1/true/yes/on` 为竞价，`0/false/no/off` 为按量；实际生效值由 `make status` 的 `billing` 字段回显，不靠记忆。

「ES 按量 + rally 竞价」这一档的理由：ES 侧的规格与收费方式决定整轮数据的可比性，值得用按量买稳定；rally 只是个发 HTTP 请求的客户端，被回收只损失一轮，重跑即可。

**改计费方式会重建实例**：`spot_strategy` 在 provider 里是 ForceNew，对已在运行的实例改这个值会销毁重建，而数据盘 `delete_with_instance = true` 会一起销毁。改之前先 `make fetch`。

### 2.5 正式测试矩阵与纪律

正式矩阵是「ES 架构 × 引擎」，**串行执行——任何时刻只存在一组资源**：

| 轮次 | ES 架构 | 引擎 | user-tags |
|---|---|---|---|
| 1 | x86 | elasticsearch | `arch=x86,engine=es` |
| 2 | x86 | easysearch | `arch=x86,engine=ez` |
| 3 | ARM | elasticsearch | `arch=arm,engine=es` |
| 4 | ARM | easysearch | `arch=arm,engine=ez` |

每轮固定四步：`make up PROFILE=<x86-main|arm-main>` → `make bench TRACK=geonames CLIENTS=8 ENGINE_NAME=<es|ez>` → `make fetch` → `make down`。

四条纪律：

1. 每轮之间必须 `make down`——串行省钱的关键，调试期最容易忘，一晚就是几十块；
2. `make fetch` 放在 `make down` 之前，或确认产物已进 OSS；
3. 起跑前 `pidstat` 确认 rally 没先饱和（见 2.1）；
4. 正式出数据的轮次用按量，竞价只用于调试。

单轮价格与节点数对比见 2.2；省钱手段的优先级是 **串行开机 > 竞价 > 降规格**，其中降规格不推荐——内存减半后 page cache 缩到 16G，HNSW 2M 数据集有风险。

### 2.6 换引擎 / 换架构

```bash
# 换引擎：建镜像 → 切换 tfvars（镜像 ID 与 engine 成对改）→ 起环境
make image-es PROFILE=x86-main ENGINE=easysearch ES_VER=2.4.0-2969
make image-use ENGINE=easysearch ARCH=x86
make up PROFILE=x86-main ENGINE=easysearch
```

换 ES 架构直接换 `PROFILE` 即可，rally 镜像共用、不必重建。

### 2.7 镜像管理

镜像名是确定性的：`esbench-{es|ez}-{引擎版本}-{架构}`、`esbench-rally-{esrally版本}-{架构}[-corpus]`——**同名即同一组合，构建入口会先查同名可用镜像，已存在就跳过**（`FORCE=1` 强制重建，名字追加时间戳后缀）。每次构建成功都会把「日期/角色/架构/引擎/版本/镜像 ID/镜像名」追加进本地台账 `image-ids.txt`（TSV，不入库）。

```bash
make image-ls                                # 列出台账，标注 tfvars 当前指向哪张
make image-use ENGINE=easysearch ARCH=x86    # 切 ES 镜像：同步改 tfvars 的镜像 ID 与 engine
make image-use --role rally --arch arm       # 切 rally 镜像
make image-fix-names                         # 存量镜像名补版本（名字里已含版本的不动）
```

`image-use` 把「镜像 ID + engine」**成对**修改，防止只改一边——把 easysearch 的密码配置打到 elasticsearch 镜像上的错配，要压测报 401 才暴露。

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
│   ├── build-image.sh      起临时实例 → install.sh → 打镜像 → 销毁（同名镜像自动跳过）
│   ├── image.sh            镜像台账查询与切换（make image-ls / image-use）
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

- **ES 节点不配公网**：减少攻击面，也避免公网带宽干扰 RT 测量，所有运维经 rally 机跳板。安全组只有两条入向规则：SSH 22 放行 `operator_cidr`（你的出口 IP），9200-9400 放行 VPC 网段——公网上碰不到任何 ES 端口。
- **ES 节点用固定内网 IP**（vSwitch 网段从 `.10` 起顺序分配）：开机前就能算出全量节点列表，直接写进 `discovery.seed_hosts` 与 `initial_master_nodes`，避免「等实例创建后取 IP」在 Terraform 里形成循环依赖。网段 `.10` 被占就改 `main.tf` 里 `locals.es_ips` 的起始偏移。
- **拓扑沿用 geonames 基线**：双节点、每节点 16 vCPU、堆 16g，`search_worker` 合计 50、`write` 合计 32。单节点 16 核只有 25 条 `search_worker` 线程，会低估引擎差距，所以正式对比必须双节点。

### 3.2 镜像里固化了什么

`/opt/es`（引擎）、`/opt/esrally`、es 用户、内核参数（`vm.max_map_count`、关闭 THP）、sysstat。ARM 与 x86 二进制不兼容，镜像必须分架构；rally 与 ES 软件栈不同，也分开。rally 固定 ARM 后，两套 ES 共用一张客户端镜像，所以默认只需三张：

| 镜像 | 架构 | 何时需要 |
|---|---|---|
| `esbench-es-{引擎版本}-x86_64` | x86_64 | 测 x86 侧 ES |
| `esbench-es-{引擎版本}-aarch64` | aarch64 | 测 ARM 侧 ES |
| `esbench-rally-{版本}-aarch64[-corpus]` | aarch64 | 唯一的 rally 镜像，两套 ES 共用（`RALLY_ON=x86` 才需要 x86 版） |

构建用一次性临时便宜机型（2C8G），系统盘固定 40G：OS + 引擎 + 语料足够，而 ESSD 系统盘与数据盘同价，盘小镜像的快照存储费也同步下降。数据一律放数据盘 `/data`，系统盘不承担数据增长。

### 3.3 语料为什么要离线烘焙

esrally 取语料的两条网络路径，在国内 ECS 上大概率都走不通：

| 内容 | 默认来源 | 问题 |
|---|---|---|
| track 定义 | github.com/elastic/rally-tracks | 拉取不稳定 |
| 语料数据 | rally-tracks.elastic.co | 实测由 Google Cloud Storage 托管，基本不可达 |

任一失败，`esrally race` 直接起不来或长时间卡在下载。所以先把 track + 语料打成离线包、构建镜像时烘焙进去，运行期 esrally 完全不碰外网。

`prepare-corpus.sh` 的行为：track 定义优先复用本地 `corpus/geonames/`（保证与历史基线同版本，新老数据才可比）；语料按 `track.json` 声明的 `source-file` 下载，已存在则跳过；生成 sha256 清单，构建时逐条校验，**任一不符构建即失败**，不会留下语料损坏的镜像。

烘焙位置是 `/opt/rally-corpus`，**不能放 `/data`**——运行期数据盘会挂到 `/data`，把镜像里的内容遮住。开机后 userdata 把它复制到 `/data/rally/benchmarks/`（`~/.rally` 已软链过去）。`run-bench.sh` 会自动探测已铺设的 track 并改用 `--track-path`（不联网），找不到才回退 `--track=` 并打印明确告警。

### 3.4 操作系统：Alibaba Cloud Linux 4

基础镜像正则 `^aliyun_4_(x64|arm64)_20G_alibase_[0-9]{8}[.]vhd$`（`--base-image-regex` 可覆盖）。必须第 4 代的原因：

| 世代 | 系统 Python | 能否装 esrally 2.12.0（`requires-python >= 3.9`） |
|---|---|---|
| Alinux 3（Anolis 8 上游） | 3.6.8 | ❌ `pip install` 被 Requires-Python 直接挡下 |
| Alinux 4（Anolis 23 上游） | 3.10 | ✅ 开箱可用；内核更新，且对神龙/CIPU 与 ESSD 有针对性优化 |

镜像名的三个坑（都用 `DescribeImages` 实测过）：版本号里**没有** `2104`；架构写作 `x64`/`arm64`，**没有** `_64` 字面串；必须加 `[0-9]{8}[.]vhd$` 尾巴排除 AI 增强版等变体。若手动换回老世代，`install.sh` 会尝试 `dnf module install python39` 兜底，找不到才报错退出——不会静默失败。

Rocky Linux 9 也能用，`install.sh` 对它做了三件必需处理：`dnf install python3-devel gcc`（esrally 的 C 扩展编译）、关 firewalld（云上已有安全组，主机层防火墙对压测只有干扰）、SELinux 调 permissive（enforcing 下 `/opt`、`/data` 的文件上下文不对会导致启动失败）。

### 3.5 换引擎：easysearch 的安装细节

建镜像的命令见 2.6，这里只说 easysearch 与 elasticsearch 不同的地方：

- 发布地址规律（已实测 HTTP 200）：`https://release.infinilabs.com/easysearch/<channel>/[bundle/]easysearch-<版本>-linux-<amd64|arm64>.tar.gz`，脚本自动下载并校验 `.sha512`；
- 架构映射：`x86_64 → amd64`，`aarch64 → arm64`；
- 默认用 snapshot 下的 **bundle 包**（自带 JDK）：`initialize.sh` 检测到 `$ES_HOME/jdk` 就不再外网现拉 200MB 的 JDK21；它仍负责生成证书与写入 admin 密码，脚本已加 3 次重试抗网络抖动；
- 内部定制包用 `--es-pkg-url` 覆盖下载地址。

**esrally 连 easysearch 必须打两个补丁（2026-09-16 实测）**。esrally 2.12.0 直连 easysearch 2.4.0 会失败，原因有两层，都已固化进代码：

| 现象 | 原因 | 处理 |
|---|---|---|
| `UnsupportedProductError: ... the server is not Elasticsearch` | esrally 的 `_ProductChecker` 按 `version.number` 判定产品：easysearch 自报 `2.4.0`，被当作「ES 2.4.0（< 6.8）的未知产品」而拒连 | `install.sh` 往 rally venv 写 `sitecustomize.py` 补丁，**仅在服务端自述为 easysearch 时放行**该判定；连真 Elasticsearch 仍走原校验 |
| `SystemSetupError: Cluster version must be at least [6.8.0] but was [2.4.0]` | esrally 要求集群版本 ≥ 6.8.0，而 easysearch 版本号自成体系 | race 时用官方参数 `--distribution-version=7.10.2`（easysearch 2.x 基于 ES 7.10.2）：`make bench` 在 `ENGINE_NAME=ez` / `ENGINE=easysearch` 时自动带上，也可 `DIST_VERSION=…` 手动指定 |

> 补丁在**镜像内**：改完 `install.sh` 必须重建 rally 镜像才对后续轮次生效（`FORCE=1 make image-rally …`）。
> 实测通过的 race：`make bench PROFILE=arm-debug TEST_MODE=1 ENGINE_NAME=ez` —— esrally 2.12.0 → easysearch 2.4.0（ARM），25 秒完成，报告指标（indexing time / refresh / GC / store size 等）齐全。

### 3.6 本地容器验证：把建镜像的坑免费踩完

建一次镜像要起临时实例（~0.2 元 + 15~25 分钟），而安装脚本改动后必然要验几轮。先在本地 Docker 里把 `install.sh` 验掉，云上那一轮大概率一次过：

```bash
make local-validate ROLE=all                        # 两个角色都验
make local-validate ROLE=rally WITH_CORPUS=1        # 含语料烘焙与 sha256 校验
make local-validate ROLE=es ENGINE=easysearch ES_VER=2.4.0-2969
```

容器用 `linux/arm64`（Apple Silicon 原生，与阿里云 ARM 同架构）；基础镜像 `openanolis/anolisos:23` 是 Alinux 4 的上游（Python 3.10 + dnf），与目标环境最接近。需要 Docker Desktop 在运行，首次拉基础镜像约 200MB。

这套验证实际抓到过 8 个只在真跑时才暴露的问题，其中四类最有复用价值：`curl` 与镜像自带 `curl-minimal` 冲突会让整条 dnf 事务回滚（逐包安装）；easysearch 的 tar 包没有顶层目录（按顶层布局自适应）；easysearch 不含 JDK 也无离线建号工具（走官方 `initialize.sh -s` + 重试）；关 TLS 的键名是 `security.ssl.http.enabled` 而非 xpack 风格（写错等于没改，rally 连不上）。

### 3.7 设计决策

| 决策 | 理由 |
|---|---|
| Terraform 而非 ROS | provider 成熟、可跨云迁移，`.tf` 即文档 |
| 数据盘用 ESSD PL1（按档位 100G） | PL1 的 350MB/s 低于各档实例带宽上限，永不触发突发回落，速度恒定才可比；geonames 2.8G + merge 峰值 <10G + HNSW 3.9G，不够可在线扩容 |
| 堆固定 16g | 与基线一致；GC 停顿更短、p99 更稳；64G 机器余约 48G 给 page cache |
| 报告文件名带时间戳 | esrally 对已存在的 markdown 报告是**追加**不是覆盖，重名会混入两场数据 |

---

## 4. 已知限制

1. **认证账号是 `admin`，两个引擎密码不同**：elasticsearch → `Qwer@123`（用 `elasticsearch-users` 离线写入 file realm）；easysearch → `Qwer@1234`（它的密码策略硬性要求 ≥9 位，`Qwer@123` 会被拒）。两个值都由 Makefile 的 `ENGINE_PASS` 按引擎派生，镜像构建与开机健康检查同源，不会不一致——**但这是公开的默认口令，正式对外交付前务必改掉**。
2. **查询侧并发需要改 track**：geonames 的 `challenges/default.json` 里并发参数只有 `bulk_indexing_clients`（写入侧），搜索任务（`term`/`default`/`phrase`/`scroll`）没有 `clients`、走 esrally 默认 1——这正是历史 race 出现「latency == service time、零排队」的原因。要测查询吞吐上限，另存一份给搜索任务加了 `"clients": ...` 的 track 专用于爬坡，**保留原始 track 不动**才能与基线可比。
3. **segment 数要用 `GET /_cat/segments/<索引>`**，不要用 `_all`——easysearch 的 `_all` 会计入 `.security` 索引，段数会虚高。
4. **起跑前的环境一致性校验尚未内建**：`run-bench.sh` 目前只采集最简指纹（CPU 型号/核数/内存/governor/THP），没有绑核与背景负载检查。在同一台机器被其他业务占用时，结果可能不可比——需要更严格的隔离时，建议在起跑前手工确认 CPU 争用与 NUMA/绑核设置。

---

## 5. 排查对照表

| 现象 | 大概率原因 | 怎么查 |
|---|---|---|
| `terraform apply` 报缺镜像 ID | 镜像没建或架构填错 | 报错会点名该填哪个字段、先跑哪条命令 |
| SSH 连不上新实例 | `operator_cidr` 没放行你的出口 IP | 查安全组规则；`curl -4 ifconfig.me` 取真实 IP，IP 变了改 tfvars 重新 apply |
| 实例起来了但 ES 没起 | userdata 失败 | `make ssh-es1 'cat /var/log/es-init.log'` |
| 集群只有一个节点 | seed_hosts / 固定 IP 未生效 | `curl localhost:9200/_cat/nodes?v`；核对 vSwitch 网段 `.10` 是否被占用 |
| rally 连不上 ES | 安全组或凭证不对 | `make ssh-rally 'cat /etc/es-targets.conf'`；rally 机上 curl 一下 9200 |
| bench 卡在下载 / 找不到 track | 镜像没烘焙语料 | `WITH_CORPUS=1` 重建 rally 镜像；`make ssh-rally 'ls /data/rally/benchmarks/tracks/'` |
| bench 报 report 文件已存在 | 报告名重复（esrally 追加不覆盖） | 脚本已带时间戳；手改过文件名需注意 |
| 产物取不到 | fetch 时实例已销毁且 OSS 没写成功 | 改用 `make fetch FROM=instance`（需实例还在）；或检查 `ossutil64` 配置与实例 RAM 角色权限 |
