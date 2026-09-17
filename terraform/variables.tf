variable "region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

variable "zone_id" {
  description = "可用区，所有实例必须同一可用区"
  type        = string
  default     = "cn-hangzhou-i"
}

variable "project" {
  type    = string
  default = "esbench"
}
variable "env" {
  type    = string
  default = "perf"
}
variable "owner" {
  type    = string
  default = "perf-team"
}

# ---------- 多环境切片键 ----------
variable "stack" {
  description = <<-EOT
    环境切片键。同一个目录、同一份代码下，用不同的 stack 并存多套互不干扰的环境
    （典型用途：x86 与 ARM 两套同时跑，把跨时段漂移消掉）。

    它会被注入到三处，缺一不可：
      - 云上资源名（VPC / vSwitch / 安全组 / SSH 密钥对 / 集群名）
      - terraform workspace（即 state 文件位置，由 scripts/tf.sh 负责切换）
      - 本地产物目录 results/<stack>/ 与 OSS 归档前缀
    因此必须是小写字母/数字/短横线 —— 它会变成资源名和 OSS 路径的一部分。

    "default" 表示不切片：资源名退化为 project-env，集群名不加后缀，
    与引入本变量之前的历史命名**完全一致**，所以已有环境不会出现任何重建。
  EOT
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.stack))
    error_message = "stack 只能是小写字母/数字/短横线，1~16 位（它要进资源名、workspace 名与 OSS 路径）"
  }

  # 资源名形如 <prefix>-<stack>-<role>[-N]，而 default 栈是 <prefix>-<role>[-N]。
  # 所以 stack 一旦长得像角色名，别人（和 scripts/stacks.sh）就无法从名字反推归属。
  validation {
    condition     = !can(regex("^(es|rally)(-|$)", var.stack))
    error_message = "stack 不能是 es / rally 或以它们加短横线开头 —— 资源名里这两个词已经表示角色，会造成归属歧义"
  }
}

variable "vpc_cidr" {
  type    = string
  default = "172.16.0.0/16"
}
variable "vswitch_cidr" {
  type    = string
  default = "172.16.1.0/24"
}

variable "operator_cidr" {
  description = <<-EOT
    允许 SSH 的出口网段，务必收紧，不要 0.0.0.0/0。
    Makefile 在 up/plan 时按 OPERATOR_CIDR > tfvars 值 > 自动探测出口 IP 的优先级解析；
    留空（推荐）即自动探测，固定出口（公司网段/跳板机）才在 tfvars 显式填写。
  EOT
  type        = string
}

variable "public_key" {
  description = "SSH 公钥内容；留空则用密码登录"
  type        = string
  default     = ""
}

variable "instance_password" {
  description = "未使用密钥时的登录密码（敏感）"
  type        = string
  default     = ""
  sensitive   = true
}

variable "rally_bandwidth" {
  description = <<-EOT
    rally 机出网带宽峰值（Mbps）。按流量计费下带宽峰值不额外收费，
    而入网带宽 = max(10, 出网带宽)，所以开大反而下载更快。
    默认 100：构建/调试时从公网拉包可达 100Mbps，且入方向流量免费。
  EOT
  type        = number
  default     = 100
}

variable "assign_public_ip" {
  description = "是否分配公网 IP。false 时只能从同 VPC 或经堡垒机访问"
  type        = bool
  default     = true
}

# ---------- 机型 ----------
variable "es_node_count" {
  description = "ES 节点数，2 为推荐（与基线拓扑一致）"
  type        = number
  default     = 2
}

# ---------- 档位：机型与镜像的配套组合 ----------
variable "profile" {
  description = <<-EOT
    档位，一句话切换机型。可选：
      debug      x86 2C8G × 1 节点 —— 只为把脚本跑通，约 1.05 元/时
      arm-debug  ARM 2C8G × 1 节点 —— 同上，但用 ARM，约 0.80 元/时（便宜 23.5%）
      x86-cheap  x86 8C32G  —— 流程验证 + 双节点集群发现
      x86-main   x86 16C64G —— 主力档，与基线算力对齐
      arm-cheap  ARM 8C32G  —— ARM 侧流程验证
      arm-main   ARM 16C64G —— ARM 主力档
    档位会自动选对应架构的镜像，避免 ARM 机型配到 x86 镜像。
  EOT
  type        = string
  default     = "debug"

  validation {
    condition     = contains(["debug", "arm-debug", "x86-cheap", "x86-main", "arm-cheap", "arm-main"], var.profile)
    error_message = "profile 只能是 debug | arm-debug | x86-cheap | x86-main | arm-cheap | arm-main"
  }
}

# ---------- rally 客户端架构（独立于 ES 架构） ----------
variable "rally_arch" {
  description = <<-EOT
    rally 客户端用哪种架构：arm（默认）| x86
    rally 只负责发 HTTP 请求，计算都在服务端，因此它的架构不影响服务端测量；
    而 ARM 比同规格 x86 便宜约 23.5%，所以默认走 ARM。
    唯一前提是 ARM 单核算力足以压满服务端 —— 用 pidstat 看 rally 进程 %CPU，
    若在服务端进入平台期之前就逼近 100%，说明客户端先饱和，改回 x86 或升规格。
  EOT
  type        = string
  default     = "arm"

  validation {
    condition     = contains(["arm", "x86"], var.rally_arch)
    error_message = "rally_arch 只能是 arm 或 x86"
  }
}

# ---------- 镜像（按架构分别构建，由档位与 rally_arch 自动选取） ----------
variable "es_image_id_x86" {
  type    = string
  default = ""
}
variable "es_image_id_arm" {
  type    = string
  default = ""
}
variable "rally_image_id_x86" {
  type    = string
  default = ""
}
variable "rally_image_id_arm" {
  type    = string
  default = ""
}

# ---------- 机型覆盖（可选，留空则用档位默认值） ----------
variable "es_instance_type_override" {
  description = "临时覆盖 ES 机型，留空用档位默认"
  type        = string
  default     = ""
}

variable "rally_instance_type_override" {
  description = "临时覆盖 rally 机型，留空用档位默认"
  type        = string
  default     = ""
}

# ---------- 存储 ----------
variable "es_data_disk_size" {
  type    = number
  default = 500
}
variable "es_data_disk_pl" {
  type    = string
  default = "PL1"
}
variable "rally_data_disk_size" {
  type    = number
  default = 200
}
variable "rally_data_disk_pl" {
  type    = string
  default = "PL1"
}

variable "es_data_disk_category" {
  description = "ES 数据盘类型。统一用 cloud_essd：g8i/g8y 不支持高效云盘（cloud_efficiency），传了会 InvalidDataDiskCategory"
  type        = string
  default     = "cloud_essd"
}

variable "rally_data_disk_category" {
  description = "rally 数据盘类型"
  type        = string
  default     = "cloud_essd"
}

# ---------- 引擎 ----------
variable "engine" {
  description = "elasticsearch | easysearch"
  type        = string
  default     = "elasticsearch"
}

variable "engine_home" {
  description = "引擎安装目录，镜像内已固化"
  type        = string
  default     = "/opt/es"
}

variable "es_heap_gb" {
  # 0 = 按机型内存自动（50%，下限 1G / 上限 31G）。
  # 默认值不能写死 16：arm-debug(2C8G)、debug 这类小机型会直接 OOM
  # （JVM mmap 16GiB 失败，ES 起不来）。正式档要与基线对齐时再显式设 16
  # （前提：机器内存 >= 32G）。
  description = "JVM 堆大小 GB；0 表示按机型内存自动计算"
  type        = number
  default     = 0
}

variable "es_data_dir" {
  type    = string
  default = "/data/es"
}
variable "cluster_name" {
  type    = string
  default = "esbench"
}
variable "es_http_port" {
  type    = number
  default = 9200
}
variable "rally_data_dir" {
  type    = string
  default = "/data/rally"
}

variable "es_port_range" {
  description = "HTTP 端口范围"
  type        = string
  default     = "9200/9400"
}

variable "es_transport_range" {
  description = "节点间 transport 端口范围"
  type        = string
  default     = "9300/9400"
}

variable "es_transport_port" {
  description = "节点间 transport 端口，写进 discovery.seed_hosts"
  type        = number
  default     = 9300
}

variable "rally_bin" {
  description = "镜像内 esrally 可执行文件路径"
  type        = string
  default     = "/opt/esrally/bin/esrally"
}

# ---------- 产物 ----------
variable "oss_bucket" {
  description = "结果归档的 OSS bucket，实例销毁后产物仍保留"
  type        = string
}

variable "oss_prefix" {
  description = "OSS 对象前缀"
  type        = string
  default     = "esrally-results"
}

variable "ram_role_name" {
  description = "授予实例的 RAM 角色，用于免密钥写 OSS；留空则在脚本内用 AK"
  type        = string
  default     = ""
}

# ---------- 计费（按量 / 竞价） ----------
# 竞价（抢占式）约为按量价的 2 折，代价是可能被回收（回收前 5 分钟有事件通知）。
# 默认按量。三个变量的优先级：单侧变量 > 全局变量 > 按量。
variable "use_spot" {
  description = <<-EOT
    全局开关：ES 节点与 rally 客户端是否都用竞价实例（false = 按量）。
    正式出报告的轮次保持 false。
  EOT
  type        = bool
  default     = false
}

variable "es_use_spot" {
  description = <<-EOT
    ES 节点是否用竞价实例；留空（null）则跟随 use_spot。
    典型用法是「ES 按量 + rally 竞价」：ES 侧决定了整轮数据的可比性，值得用按量换稳定；
    rally 被回收只损失一轮，重跑即可。命令行传参见 README 2.2（SPOT_ES / SPOT_RALLY）。
  EOT
  type        = bool
  default     = null
  nullable    = true
}

variable "rally_use_spot" {
  description = "rally 客户端是否用竞价实例；留空（null）则跟随 use_spot"
  type        = bool
  default     = null
  nullable    = true
}

variable "es_password" {
  description = <<-EOT
    引擎 admin 账号密码，两个引擎统一：镜像构建（--es-pass）与开机健康检查共用同一个值。
    9 位是 easysearch 密码策略的下限（须含大小写/数字/特殊字符），对 elasticsearch 同样合规。
    注意引擎真实密码烘焙在建镜像时：改这个值后存量 ES 镜像要 FORCE=1 make image-es 重建。
  EOT
  type        = string
  default     = "Qwer@1234"

  validation {
    condition     = length(var.es_password) >= 9
    error_message = "密码至少 9 位（easysearch 密码策略下限），且须含大小写字母、数字与特殊字符"
  }
}

variable "system_disk_size" {
  description = <<-EOT
    系统盘大小（GiB）。系统盘与数据盘**同类型同单价**（ESSD ≈0.0021 元/GiB/时，杭州按量），
    所以"减系统盘 vs 加数据盘"只看总 GiB。
    40G 足够：OS ~3G + 引擎 ~2.5G + easysearch 的 JDK 0.6G + 语料 0.26G，还留有余量；
    自定义镜像按系统盘建快照，盘小镜像也小，镜像存储费同步下降。
    引擎数据一律放数据盘（/data），系统盘不承担数据增长。
  EOT
  type        = number
  default     = 40

  validation {
    condition     = var.system_disk_size >= 20 && var.system_disk_size <= 500
    error_message = "系统盘 20~500 GiB"
  }
}
