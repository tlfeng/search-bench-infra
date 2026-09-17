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
make image-rally PROFILE=arm-cheap WITH_CORPUS=1   # rally 客户端镜像；WITH_CORPUS=1 必须有，否则运行期拉不到语料
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

也可以一条命令跑完上面四步（`make run`，内部严格按 up → bench → fetch → down 执行，bench 失败也会 fetch、任何失败也会 down）：

```bash
make run PROFILE=arm-debug TEST_MODE=1   # DRY=1 只出计划（0 费用）；KEEP=1 保留实例排查
```

`make up` 成功后会把本轮 PROFILE/ENGINE 记到 `.stacks/<STACK>/meta`；之后 `make bench` / `make status` / `make run` 不显式传参时自动沿用，避免「up 用 arm-debug、bench 按默认档推导」造成的 arch 标签错标与就绪门禁退化。显式传参永远优先。

`make fetch` 默认从 OSS 拉，**实例销毁后照样能取**；本机没装 `ossutil64` 时自动改用 scp，那时实例必须还在——所以 fetch 要放在 down 之前（`make run` 已把这层顺序固化，手工跑四步时才需要自己记）。想强制走 scp：`make fetch FROM=instance`。

### 1.7 首次跑通：验证阶梯

脚本第一次跑大概率要调几轮。按下面顺序走，每步只验证一件事，总成本可控制在 10 元内。**建议全程用 `arm-debug` 起步**：比 x86 便宜，还能把 aarch64 侧的坑（镜像构建、esrally 依赖、引擎启动）提前暴露，而不是留到正式轮次才发现。

| 步骤 | 命令 | 成本 | 验证点 |
|---|---|---|---|
| 0 静态检查 | `make help`；`make -n up PROFILE=arm-debug` | 0 | 命令展开与传参 |
| 1 语料 | `make corpus` | 0 | 语料可获取 |
| 2 镜像 | `make image-rally PROFILE=arm-cheap WITH_CORPUS=1`<br>`make image-es PROFILE=arm-debug` | 各 ~0.2 元 | 网络依赖、语料烘焙与 sha256 校验 |
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

rally 固定用 ARM：它只发 HTTP 请求、计算都在服务端，架构不影响测量结果，而同规格 ARM 的算力比 x86 便宜约 23.5%（按 2.2 的含盘单价算是 17%~22%）。唯一前提是单核压得满服务端——起压后用 `pidstat -p $(pgrep -f esrally) 1` 看，若服务端还没进平台期、rally 的 %CPU 就逼近 100，说明客户端先饱和，`make up RALLY_ON=x86` 切回。

### 2.2 成本

**ES 节点单价**（含该机的 40G 系统盘与数据盘，2026-09 在 `cn-hangzhou` 实测）：

| ES 机型 | 实例类型 | 数据盘 | 按量/时 | 竞价/时 |
|---|---|---|---|---|
| x86 2C8G | `ecs.g8i.large` | 40G | 0.69 | 0.27 |
| ARM 2C8G | `ecs.g8y.large` | 40G | 0.57 | 0.26 |
| x86 8C32G | `ecs.g8i.2xlarge` | 100G | 2.39 | 0.71 |
| ARM 8C32G | `ecs.g8y.2xlarge` | 100G | 1.89 | 0.63 |
| x86 16C64G | `ecs.g8i.4xlarge` | 100G | 4.48 | 1.13 |
| ARM 16C64G | `ecs.g8y.4xlarge` | 100G | 3.49 | 0.97 |

**每轮 = n 台 ES + 1 台 rally**。下面的矩阵按 ES 机型分行、按 **ES 节点数**分列，**每格都已含那 1 台 rally 及其磁盘**：

```
单轮价格 = (ES 节点数 × ES 单价 + rally 单价) × 轮次小时数   # 轮次按 2 小时计
```

rally 每轮固定 1 台、固定 ARM，按 ES 规格配对：

| ES 机型 | rally 机型 | rally 单价（按量/竞价） |
|---|---|---|
| x86 2C8G（`debug` 档） | 同规格 x86 2C8G | 0.69 / 0.27 |
| ARM 2C8G（`arm-debug` 档） | 同规格 ARM 2C8G | 0.57 / 0.26 |
| x86 8C32G / ARM 8C32G | ARM 4C16G `ecs.g8y.xlarge` | 0.97 / 0.34 |
| x86 16C64G / ARM 16C64G | ARM 8C32G `ecs.g8y.2xlarge` | 1.77 / 0.50 |

轮次按 **2 小时**计（含开机、一次压测、取产物与销毁的余量）。例：x86 16C64G 三节点 = 3 × 4.48 + 1.77 = 15.21 元/时 → 一轮 30.4 元。

**单轮价格（元，每格 = 按量 / 竞价，四舍五入到 0.1 元）**：

| ES 机型 | ES ×1 | ES ×2 | ES ×3 | ES ×4 |
|---|---|---|---|---|
| x86 2C8G | 2.8 / 1.1 | 4.1 / 1.6 | 5.5 / 2.2 | 6.9 / 2.7 |
| ARM 2C8G | 2.3 / 1.0 | 3.4 / 1.6 | 4.6 / 2.1 | 5.7 / 2.6 |
| x86 8C32G | 6.7 / 2.1 | 11.5 / 3.5 | 16.3 / 4.9 | 21.1 / 6.4 |
| ARM 8C32G | 5.7 / 1.9 | 9.5 / 3.2 | 13.3 / 4.5 | 17.1 / 5.7 |
| x86 16C64G | 12.5 / 3.3 | 21.5 / 5.5 | 30.4 / 7.8 | 39.4 / 10.0 |
| ARM 16C64G | 10.5 / 2.9 | 17.5 / 4.9 | 24.5 / 6.8 | 31.5 / 8.8 |

读表前先知道三件事：

- **单价已含全部磁盘**，不用另加。ESSD PL1 云盘按量 0.0021 元/GiB/时，系统盘与数据盘同价；磁盘在单价里的占比随规格下降（2C8G 档约 24%~29%，16C64G 档约 7%）。
- **竞价只对算力打折**，磁盘按原价计，所以整套的竞价/按量比在 0.25~0.46 之间浮动（debug 档盘占比最高，比值也最高），不是固定折扣。切换方式见 2.4。
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
| `make up [PROFILE=…] [ENGINE=…] [RALLY_ON=…] [ES_NODES=…] [USE_SPOT=1] [STACK=…] [ZONE=…]` | 拉起环境；成功后把 PROFILE/ENGINE 记入 `.stacks/<STACK>/meta` |
| `make status` | IP、target-hosts、当前档位与计费方式（`billing`），含 up 记录与不一致告警 |
| `make bench [TRACK=…] [CHALLENGE=…] [CLIENTS=…] [ENGINE_NAME=es\|ez] [TEST_MODE=1] [STACK=…]` | 跑压测；PROFILE/ENGINE 缺省回读 up 记录 |
| `make run [PROFILE=…] [ENGINE=…] [CLIENTS=…] [TEST_MODE=1] [KEEP=1] [DRY=1]` | 一条命令跑完 up→bench→fetch→down（串行纪律的自动化形态） |
| `make fetch [RUN_ID=…] [FROM=instance] [STACK=…]` | 取回产物到 `results/[<stack>/]` |
| `make down [STACK=…] [CONFIRM=1]` | 销毁资源（非 default stack 需 `CONFIRM=1`） |
| `make ssh-rally` / `ssh-es1` / `ssh-es2` / `tail-rally` | 登录机器 / 看 rally 初始化日志 |
| `make stacks` | 列出所有 stack：本地 workspace/产物 + **云端仍在计费的实例**（见 2.8） |
| `make matrix [MATRIX=…]` | 按 `stacks.yaml` 并行跑多套并汇总对照表（见 2.8） |
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

每轮固定四步：`make up PROFILE=<x86-main|arm-main>` → `make bench TRACK=geonames CLIENTS=8 ENGINE_NAME=<es|ez>` → `make fetch` → `make down`。这四步已封装成一条 `make run PROFILE=<x86-main|arm-main> ENGINE=<es|ez> CLIENTS=8`：内部按同样顺序执行，且 bench 失败也会 fetch、任何失败也会 down，把「忘 fetch 就 down」这类事故从纪律变成代码保证。

四条纪律：

1. 每轮之间必须 `make down`——串行省钱的关键，调试期最容易忘，一晚就是几十块；
2. `make fetch` 放在 `make down` 之前，或确认产物已进 OSS；
3. 起跑前 `pidstat` 确认 rally 没先饱和（见 2.1）；
4. 正式出数据的轮次用按量，竞价只用于调试。

单轮价格与节点数对比见 2.2；省钱手段的优先级是 **串行开机 > 竞价 > 降规格**，其中降规格不推荐——内存减半后 page cache 缩到 16G，HNSW 2M 数据集有风险。

> **串行不是强制约束，而是一个默认选择。** 上面的四轮矩阵有一个方法论缺陷：第 1 轮与第 4 轮之间可能隔了几个小时，期间的宿主机负载与存储后端压力都会变，最后分不清差异来自引擎还是来自时段。
> 需要消掉这个漂移时改用 **2.8 的 `STACK` + `make matrix`**：两套环境在同一个时间窗内并行跑，用**同时段的相对比值**代替跨时段的绝对值比较。这**不额外花钱**（同样的轮数就是同样的总机时，只是压缩了时间轴，见 2.8 的成本口径），代价是同时占用更多配额、且必须错开可用区。

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

`image-use` 把「镜像 ID + engine」**成对**修改，防止只改一边——镜像里的引擎与 `ENGINE` 变量错位后，esrally 的版本判定（`--distribution-version`）与 user-tags 会全错，到压测出数才发现。

### 2.8 多环境并存（STACK）与并发的测量纪律

默认情况下这套基础设施**任何时刻只存在一套资源**（2.5 的串行纪律）。要让多套环境并存，用 `STACK` 打开切片：

```bash
make up    STACK=x PROFILE=x86-main ENGINE=elasticsearch ZONE=cn-hangzhou-b VPC_CIDR=172.16.0.0/16 VSWITCH_CIDR=172.16.1.0/24
make up    STACK=a PROFILE=arm-main ENGINE=elasticsearch ZONE=cn-hangzhou-j VPC_CIDR=172.17.0.0/16 VSWITCH_CIDR=172.17.1.0/24
make bench STACK=x TRACK=geonames CLIENTS=8
make fetch STACK=x                     # 产物落到 results/x/
make stacks                            # 一眼看清云端到底有几套在烧钱
make down  STACK=x CONFIRM=1           # 非 default stack 必须显式确认
```

`STACK` 是**唯一切片键**，它会同时决定下面六件事——少覆盖任何一层，两套环境就会互相踩：

| 层 | default | `STACK=x` | 少覆盖的后果 |
|---|---|---|---|
| 资源名 | `esbench-perf-es-1` | `esbench-perf-x-es-1` | SSH 密钥对名在 region 内**全局唯一**，第二套 apply 直接报 `KeyPair.AlreadyExist` |
| terraform state | `terraform.tfstate` | `terraform.tfstate.d/x/`（workspace） | 第二次 `make up` 变成"改写第一套"：`count` 不同会直接把已有节点销毁重建 |
| provider 缓存 | `.stacks/default/` | `.stacks/x/` | 并发 `init` 互相改写 `.terraform/environment`（"当前 workspace"指针），apply 会打到别的栈上 |
| 本地产物 | `results/` | `results/x/` | 两台 rally 机的产物混进同一目录，`fetch` 分不清谁是谁 |
| OSS 归档 | `esrally-results/` | `esrally-results/x/` | `make fetch`（不带 `RUN_ID` = 拉整个前缀）会把多套产物拉成一坨 |
| up 环境记录 | `.stacks/default/meta` | `.stacks/x/meta` | `make bench` 回读到**别的栈**的 PROFILE/ENGINE：arch 错标、就绪门禁节点数对不上 |

**`STACK=default`（即不传）与历史行为逐字一致**，已在真实 state 上验证为 `0 to add / 0 to change / 0 to destroy`（只多两个 output）。所以引入这套机制不会让任何已有环境被判定为需要重建。

#### 并发到底为了什么

不是为了省时间，而是**消掉跨时段漂移**。串行四轮里第 1 轮和第 4 轮可能差几个小时，期间云侧宿主机负载、同宿主邻居压力、存储后端拥塞都变了，最后分不清差异来自引擎还是来自时段。并发强制它们在同一个时间窗内跑——这才是并发对照在方法论上站得住的地方。

#### 但并发有它自己的代价：三条纪律

1. **两栈尽量落在不同可用区**。同可用区的两套实例共享 ESSD 后端带宽与内网路径。注意杭州（cn-hangzhou）的 g8y/g8i 大规格实测**只有 b / j / k 有货，`-c` 无货**，所以并发两套用 `b + j` 或 `b + k`。`make matrix` 会自动查这个库存并给出建议。
2. **并发只用于冒烟 / 链路验证 / 交叉初筛**；正式出报告的轮次仍走 2.5 的串行纪律。
3. **只做 stack 之间的相对比较**，各栈绝对值只与「同时段、同 stack」的历史比。与 `shared-bench-host-consistency` 的判据一致：共享资源上不追求环境稳定，只保证结果可比。

#### `make matrix`：按声明并行跑

`stacks.yaml` 声明要跑哪些栈，`make matrix` 并行执行每栈的 `up → bench → fetch → down`：

```bash
make matrix                    # 交互确认后开跑
make matrix EXTRA_ARGS="--dry-run"              # 只打印计划 + 库存预检，0 费用
make matrix EXTRA_ARGS="--stacks x,a"           # 只跑指定的栈
make matrix EXTRA_ARGS="--parallel 1"           # 退化成串行（做对照用）
make matrix EXTRA_ARGS="--no-down"              # 保留实例，便于登进去查问题
```

设计上的三个硬约束：

- **`down` 放在每栈自己的流水线里**，不是等全部跑完统一销毁——哪套先跑完就先释放它的计费资源；
- **bench 失败也要 fetch、任何一步失败也要 down**——产物在实例数据盘上，实例一销毁就没了；反过来资源不销毁就是持续计费；
- **库存预检只警告不阻断**，且"查询失败"必须报"未知"而不是"无货"——假警报比不报更糟（会让人对真警报麻木）。要硬跑加 `--no-preflight`。

跑完自动生成 `results/_matrix/<ts>/summary.md`：环境对照、引擎侧关键指标（写入吞吐 / 体积 / 段数 / merge / p50 p100 延迟）、各 task 中位吞吐、以及一致性自检（error rate、核数、段数、耗时）。汇总表**只做机械汇总、不下结论**，口径声明写在表头。

#### 成本口径：并发不额外花钱（这一条容易被想反）

**跑 N 套与串行跑 N 轮，总实例时长相同、总花费相同。** 并发只是把同一批机时压进更短的时间窗：

| | 总花费 | 墙钟 |
|---|---|---|
| 串行 2 轮（各 1 小时） | 10.50 元 | 2.0 小时 |
| 并发 2 套（各 1 小时） | 10.50 元 | 1.0 小时 |

（实测 cn-hangzhou 按量：`x86-cheap` 腿 5.74 元/时、`arm-cheap` 腿 4.76 元/时，均含系统盘与数据盘。）

所以省钱的优先级 **串行开机 > 竞价 > 降规格** 依然成立——它管的是"总机时"；并发动的是"机时在时间轴上怎么摆"，不动总量。真正的代价是另外三项：

1. **同时占用 N 倍 vCPU 配额**（两套 `*-main` 含 rally = 2 × (32 + 8) = 80 vCPU，可能触顶；`make matrix` 预检按这个口径查余量）；
2. **爆炸半径变大**：任一套漏了 `down`，同时在烧的钱是 N 倍。`make stacks` 就是为盯这个而存在的；
3. **竞价回收的并发暴露面更大**：同一时间窗内 N 套都在被回收风险下，不如串行摊开。

换句话说：**并发是用"配额与运维风险"换"墙钟时间"，不是用钱换。** 这一点搞清楚之后，"要不要并发"就变成一个纯粹的判断——你需不需要那两小时。

---

## 3. 工作原理

```
目录结构（省略零散文件）：
├── Makefile                编排入口（setup/corpus/image-*/up/bench/run/fetch/down/stacks/matrix）
├── stacks.yaml             并行矩阵声明：要同时跑哪几套环境（见 2.8）
├── terraform/              VPC/安全组/ECS/云盘
│   └── terraform.tfvars    真实参数，不入库（make setup 生成）
├── scripts/
│   ├── bootstrap.sh        新机器引导（make setup）
│   ├── tf-env.sh           把 ~/.aliyun/config.json 的凭据注入 terraform（仅内存）
│   ├── tf.sh               terraform 的唯一入口：TF_DATA_DIR + workspace 切换
│   ├── build-image.sh      起临时实例 → install.sh → 打镜像 → 销毁（同名镜像自动跳过）
│   ├── image.sh            镜像台账查询与切换（make image-ls / image-use）
│   ├── install.sh          镜像内安装引擎与 esrally
│   ├── prepare-corpus.sh   语料离线包（本机，0 费用）
│   ├── userdata-*.sh.tpl   开机初始化（挂盘/配置/启动）
│   ├── run-bench.sh        触发压测 + 归档 OSS
│   ├── fetch-results.sh    拉取产物
│   ├── stacks.sh           列出全部环境（本地 + 云端在计费的实例）
│   ├── local-validate.sh   本地 Docker 验证 install.sh（make local-validate）
│   ├── bench-matrix.sh     并行跑多套（up→bench→fetch→down）+ 库存预检；make run 复用它的单栈流水线
│   └── matrix-summary.sh   把各栈报告汇总成对照表
├── .stacks/                每 stack 的 provider 缓存、workspace 指针与 up 环境记录 meta（不入库）
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
| 多环境用 `STACK` 单一变量 + terraform workspace 切片 | 只加 `-state` 参数是 legacy、且不解决命名冲突（SSH 密钥对名 region 内唯一）；只加 workspace 同样撞 key pair，且 `.terraform/environment` 是全局共享的"当前 workspace"指针，一个调用点忘了 select 就会 apply 到别的栈上。解法是**一个切片键贯穿六层**，并把所有 terraform 调用收进 `scripts/tf.sh`（只剩一处可能出错） |
| `stack=default` 完全退化为历史命名 | 引入隔离能力的那一天，不能把已有环境判成需要重建。已用真实 state 验证为 `0 to add / 0 to change / 0 to destroy` |
| `stacks.yaml` 只支持最小 YAML 子集，嵌套/行内集合直接报错 | 静默按一份自己没写过的配置去开机器，比拒绝执行贵得多 |
| 并压矩阵里 `down` 放进每栈自己的流水线 | 哪套先跑完就先释放它的计费资源；统一在末尾销毁会让先完成的栈白白多烧一两个小时 |
| 库存预检只警告、且"查询失败"报"未知"而非"无货" | 预检的目的是提前说出"云上开不出来"，不是替人决定能不能跑；把查询失败当成无货会制造假警报，假警报比不报更糟 |
| `tf-env.sh` 的提示语一律走 stderr | 调用方常写 `$(tf.sh output -raw ...)`，混进 stdout 的提示语会把返回值污染成一句中文（`fetch-results.sh` 真的踩过） |
| up 时把 PROFILE/ENGINE 落盘 `.stacks/<stack>/meta`，bench/status/run 缺省回读 | 没传参时的默认值应该来自「这套环境自己」，而不是 Makefile 全局默认——否则 up 用 arm-debug、bench 按默认档推导，arch 错标 + 就绪门禁退化成 1 节点，错得悄无声息。显式传参永远优先；`image-*` 等构建类目标不回读，防止镜像架构被上次 up 带偏 |
| 引擎版本 pin 死，不自动拉最新 | 版本是被测对象的一部分，静默升级会让两轮结果不可比；elastic 没有 latest 端点，解析页面只会给脆弱的国内链路再加一层不确定。升级 = 改 `ES_VER` 一处 → 建新镜像（名字含版本，新旧并存）→ `image-use` 切换 |
| 所有脚本里 `$VAR` 紧跟中文/全角字符一律写成 `${VAR}` | macOS 自带 bash 3.2 会把多字节字节并进变量名：`$PAR）` 查的是名为 `PAR）` 的变量，`set -u` 下直接 `unbound variable` 崩溃（无 `set -u` 时静默输出空值），Linux bash 5 无此问题——这类雷只在 macOS 上炸 |

---

## 4. 已知限制

1. **认证账号是 `admin`，两个引擎密码统一为 `Qwer@1234`**：9 位是 easysearch 密码策略的下限（≥9 位），对 elasticsearch 同样合规，于是两边同源（Makefile 的 `ENGINE_PASS` 一个值，镜像构建与开机健康检查共用），不存在不一致的可能——**但这是公开的默认口令，正式对外交付前务必改掉**。注意引擎真实密码是**建镜像时烘焙**的（`elasticsearch-users` 离线写入 file realm / easysearch 的 `initialize.sh`）：改默认值后，存量 ES 镜像（内嵌旧口令）必须 `FORCE=1 make image-es PROFILE=<档>` 重建，否则开机健康检查与 rally 全部 401；easysearch 镜像本来就是 9 位，无需重建。
2. **查询侧并发需要改 track**：geonames 的 `challenges/default.json` 里并发参数只有 `bulk_indexing_clients`（写入侧），搜索任务（`term`/`default`/`phrase`/`scroll`）没有 `clients`、走 esrally 默认 1——这正是历史 race 出现「latency == service time、零排队」的原因。要测查询吞吐上限，另存一份给搜索任务加了 `"clients": ...` 的 track 专用于爬坡，**保留原始 track 不动**才能与基线可比。
3. **segment 数要用 `GET /_cat/segments/<索引>`**，不要用 `_all`——easysearch 的 `_all` 会计入 `.security` 索引，段数会虚高。
4. **起跑前的环境一致性校验尚未内建**：`run-bench.sh` 目前只采集最简指纹（CPU 型号/核数/内存/governor/THP），没有绑核与背景负载检查。在同一台机器被其他业务占用时，结果可能不可比——需要更严格的隔离时，建议在起跑前手工确认 CPU 争用与 NUMA/绑核设置。
5. **并发对照的可信度有上限，且这个上限无法用代码消除**：`make matrix` 能保证两套环境互不干扰（网络 / state / 命名 / 产物全部隔离），但**消不掉云侧共享层**——同可用区的 ESSD 后端带宽、内网路径、账号级配额。所以并发结果只作 stack 之间的相对比较。而且杭州的大规格实测只有 `b` / `j` / `k` 三个可用区有货，能错开的选择本就有限。这一条与 `shared-bench-host-consistency` 的判据一致：共享资源上不追求环境稳定，只保证结果可比。
6. **库存预检依赖 `DescribeAvailableResource`，它返回的是快照不是预留**：预检通过不代表一定开得出来（紧俏规格与竞价实例尤甚）。反过来，预检失败时会明确报"未知"而不是"无货"，避免制造假警报。
7. **`make stacks` 靠实例名前缀反推归属**：规则是 `<prefix>-<role>[-N]` → default、`<prefix>-<stack>-<role>[-N]` → 该 stack。因此 stack 名不能取 `es` / `rally`（terraform 的 validation 已拦住），实例名前缀也要保持 `project-env` 的形态。

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
| `make bench` 提示「无 up 记录」或「与 up 记录不一致」 | 环境不是当前 PROFILE 推导的这套；或环境是旧版 up 建的、还没有 meta | `make status` 看「记录」行核对；对不上就显式传 `PROFILE=` 或重跑一次 `make up` |
| 忘了带 `STACK=`，操作到了别的环境 | Makefile 的 `STACK` 默认 `default`，而资源在 `x` 上 | `make stacks` 看云端实例与 workspace 列表；`make status STACK=x` 确认 |
| 开第二套报 `KeyPair.AlreadyExist` | 资源名没带 stack（SSH 密钥对名 region 内全局唯一） | `make plan STACK=x` 看资源名是否带 `-x-` 前缀 |
| 第二套 `make up` 把第一套改了 / 删了 | state 没隔离（workspace 未生效） | `make stacks` 看 workspace 列表；确认调用都走 `scripts/tf.sh` 而不是裸 `terraform` |
| `make matrix` 报某栈可用区无货 | 目标 zone 该机型无库存 | 预检会直接列出有货可用区；杭州大规格只有 `b` / `j` / `k` |
| `make matrix` 跑完但某栈没有可比数据 | 该栈 up 或 bench 失败，产物缺失 | 看 `results/_matrix/<ts>/<stack>.log`；汇总表会把缺产物的栈标成「（无产物）」 |
| 汇总表里 `error rate` 不为 0 | 有请求失败，吞吐数字无意义 | 先看该栈 `rally.log`，再看 `cluster-watch.log` 判断是否实例被回收 |
| `make down STACK=x` 拒绝执行 | 非 default stack 的保护，需要 `CONFIRM=1` | `make down STACK=x CONFIRM=1`（先 `make fetch STACK=x` 取回产物） |
