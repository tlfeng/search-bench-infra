terraform {
  required_version = ">= 1.5"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.220"
    }
  }
}

provider "alicloud" {
  region = var.region
}

locals {
  name_prefix = "${var.project}-${var.env}"
  common_tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    managed = "terraform"
  }

  # ES 节点固定内网 IP（从 .10 起，避开阿里云 VPC 保留的前几个地址）。
  # 必须固定：双节点要靠 seed_hosts 互相发现，而 user_data 在实例创建时就已确定，
  # 若等创建后再取 private_ip 会形成循环依赖。预先算出即可直接写进配置。
  es_ips = [for i in range(var.es_node_count) : cidrhost(var.vswitch_cidr, 10 + i)]
}

# ES 侧：档位 → 机型 + 镜像 + 规格档（cheap/main）。
# 把「机型」和「镜像架构」绑在一起，避免 ARM 机型配 x86 镜像这类必然失败的错误。
locals {
  es_by_profile = {
    # debug：最小规格、单节点，只为把「建镜像 → 起机 → 引擎起来 → rally 连上」这条链路跑通
    "debug" = { arch = "x86_64", size = "debug", type = "ecs.g8i.large", image = var.es_image_id_x86 }
    # arm-debug：同上但走 ARM（2C8G 比 x86 便宜 23.5%），且能提前暴露 aarch64 侧
    # 的兼容性问题（镜像构建、esrally 依赖、引擎启动），而不是留到正式轮次才发现
    "arm-debug" = { arch = "aarch64", size = "debug", type = "ecs.g8y.large", image = var.es_image_id_arm }
    "x86-cheap" = { arch = "x86_64", size = "cheap", type = "ecs.g8i.2xlarge", image = var.es_image_id_x86 }
    "x86-main"  = { arch = "x86_64", size = "main", type = "ecs.g8i.4xlarge", image = var.es_image_id_x86 }
    "arm-cheap" = { arch = "aarch64", size = "cheap", type = "ecs.g8y.2xlarge", image = var.es_image_id_arm }
    "arm-main"  = { arch = "aarch64", size = "main", type = "ecs.g8y.4xlarge", image = var.es_image_id_arm }
  }
}

# rally 侧：架构独立于 ES（默认 ARM，比同规格 x86 便宜约 23.5%），
# 规格大小跟随 ES 档位（cheap → 4C16G / main → 8C32G）。
locals {
  rally_by_key = {
    "arm-debug" = { type = "ecs.g8y.large", image = var.rally_image_id_arm }
    "arm-cheap" = { type = "ecs.g8y.xlarge", image = var.rally_image_id_arm }
    "arm-main"  = { type = "ecs.g8y.2xlarge", image = var.rally_image_id_arm }
    "x86-debug" = { type = "ecs.g8i.large", image = var.rally_image_id_x86 }
    "x86-cheap" = { type = "ecs.g8i.xlarge", image = var.rally_image_id_x86 }
    "x86-main"  = { type = "ecs.g8i.2xlarge", image = var.rally_image_id_x86 }
  }
}

locals {
  _es = local.es_by_profile[var.profile]
  _rk = "${var.rally_arch}-${local._es.size}"

  prof = {
    arch = local._es.arch

    es_instance_type = var.es_instance_type_override != "" ? var.es_instance_type_override : local._es.type
    es_image_id      = local._es.image

    rally_arch          = var.rally_arch == "arm" ? "aarch64" : "x86_64"
    rally_instance_type = var.rally_instance_type_override != "" ? var.rally_instance_type_override : local.rally_by_key[local._rk].type
    rally_image_id      = local.rally_by_key[local._rk].image
  }
}

# ---------- 网络 ----------
resource "alicloud_vpc" "this" {
  vpc_name   = "${local.name_prefix}-vpc"
  cidr_block = var.vpc_cidr
  tags       = local.common_tags
}

resource "alicloud_vswitch" "this" {
  vpc_id       = alicloud_vpc.this.id
  cidr_block   = var.vswitch_cidr
  zone_id      = var.zone_id
  vswitch_name = "${local.name_prefix}-vsw"
  tags         = local.common_tags
}

# ---------- 安全组 ----------
resource "alicloud_security_group" "es" {
  security_group_name = "${local.name_prefix}-sg-es"
  vpc_id              = alicloud_vpc.this.id
  security_group_type = "normal"
  tags                = local.common_tags
}

# SSH 仅放行运维出口 IP
resource "alicloud_security_group_rule" "ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  security_group_id = alicloud_security_group.es.id
  cidr_ip           = var.operator_cidr
  priority          = 1
}

# ES 端口仅放行 VPC 内网（rally 与节点互访）
resource "alicloud_security_group_rule" "es_internal" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = var.es_port_range
  security_group_id = alicloud_security_group.es.id
  cidr_ip           = var.vpc_cidr
  priority          = 1
}

resource "alicloud_security_group_rule" "es_transport" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = var.es_transport_range
  security_group_id = alicloud_security_group.es.id
  cidr_ip           = var.vpc_cidr
  priority          = 1
}

# ---------- SSH 密钥 ----------
resource "alicloud_key_pair" "this" {
  count         = var.public_key != "" ? 1 : 0
  key_pair_name = "${local.name_prefix}-key"
  public_key    = var.public_key
}

# ---------- ES 节点（双节点） ----------
resource "alicloud_instance" "es" {
  count                = var.es_node_count
  instance_name        = "${local.name_prefix}-es-${count.index + 1}"
  instance_type        = local.prof.es_instance_type
  image_id             = local.prof.es_image_id
  availability_zone    = var.zone_id
  vswitch_id           = alicloud_vswitch.this.id
  security_groups      = [alicloud_security_group.es.id]
  key_name             = var.public_key != "" ? alicloud_key_pair.this[0].key_pair_name : null
  instance_charge_type = "PostPaid"
  spot_strategy        = var.use_spot ? "SpotAsPriceGo" : "NoSpot"
  private_ip           = local.es_ips[count.index]
  # ES 节点永不分配公网：所有运维经 rally 机跳板走内网，减少攻击面也避免带宽费
  internet_max_bandwidth_out = 0
  password                   = var.public_key != "" ? null : var.instance_password
  system_disk_category       = "cloud_essd"
  system_disk_size           = var.system_disk_size
  tags                       = merge(local.common_tags, { role = "es" })

  data_disks {
    name     = "es-data"
    size     = var.es_data_disk_size
    category = var.es_data_disk_category
    # performance_level 只对 cloud_essd 有效，高效云盘传了会报错
    performance_level    = var.es_data_disk_category == "cloud_essd" ? var.es_data_disk_pl : null
    delete_with_instance = true
  }

  user_data = base64encode(templatefile("${path.module}/../scripts/userdata-es.sh.tpl", {
    node_index        = count.index + 1
    node_count        = var.es_node_count
    heap_gb           = var.es_heap_gb
    engine            = var.engine
    engine_home       = var.engine_home
    data_dir          = var.es_data_dir
    cluster_name      = var.cluster_name
    es_port           = var.es_http_port
    es_ips            = join(",", local.es_ips)
    es_transport_port = var.es_transport_port
    es_password       = var.es_password
  }))

  # 镜像 ID 缺失是最常见的卡点（换档位或换 rally 架构后忘了配镜像），提前给出可读错误
  lifecycle {
    precondition {
      condition = (
        local.prof.es_image_id != "" &&
        local.prof.rally_image_id != ""
      )
      error_message = join(" ", [
        "缺少镜像 ID。",
        "ES 侧是 ${local.prof.arch}，需要 ${local.prof.arch == "aarch64" ? "es_image_id_arm" : "es_image_id_x86"}；",
        "rally 侧是 ${local.prof.rally_arch}，需要 ${local.prof.rally_arch == "aarch64" ? "rally_image_id_arm" : "rally_image_id_x86"}。",
        "先执行 make image-all（ES）与 make image-rally（rally）构建，再把输出的 ID 填回 terraform.tfvars。",
      ])
    }
  }
}

# ---------- esrally 客户端 ----------
resource "alicloud_instance" "rally" {
  instance_name        = "${local.name_prefix}-rally"
  instance_type        = local.prof.rally_instance_type
  image_id             = local.prof.rally_image_id
  availability_zone    = var.zone_id
  vswitch_id           = alicloud_vswitch.this.id
  security_groups      = [alicloud_security_group.es.id]
  key_name             = var.public_key != "" ? alicloud_key_pair.this[0].key_pair_name : null
  instance_charge_type = "PostPaid"
  spot_strategy        = var.use_spot ? "SpotAsPriceGo" : "NoSpot"
  # 按流量计费（internet_charge_type 默认 PayByTraffic）：只对出方向收费，
  # 下载（入方向）免费；带宽峰值不额外计费，所以开大只会让下载更快。
  # 入网带宽 = max(10, 出网带宽)，设 100 才能拿到 100Mbps 入网。
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.assign_public_ip ? var.rally_bandwidth : 0
  password                   = var.public_key != "" ? null : var.instance_password
  system_disk_category       = "cloud_essd"
  system_disk_size           = var.system_disk_size
  tags                       = merge(local.common_tags, { role = "rally" })

  data_disks {
    name                 = "rally-data"
    size                 = var.rally_data_disk_size
    category             = var.rally_data_disk_category
    performance_level    = var.rally_data_disk_category == "cloud_essd" ? var.rally_data_disk_pl : null
    delete_with_instance = true
  }

  user_data = base64encode(templatefile("${path.module}/../scripts/userdata-rally.sh.tpl", {
    data_dir    = var.rally_data_dir
    oss_bucket  = var.oss_bucket
    oss_prefix  = var.oss_prefix
    es_hosts    = join(",", local.es_ips)
    es_port     = var.es_http_port
    rally_bin   = var.rally_bin
    es_password = var.es_password
  }))
}

# 用独立资源绑定 RAM 角色（provider 1.275.0 起，instances 上的 role_name 已废弃）
resource "alicloud_ecs_ram_role_attachment" "es" {
  count         = var.ram_role_name != "" ? var.es_node_count : 0
  instance_id   = alicloud_instance.es[count.index].id
  ram_role_name = var.ram_role_name
}

resource "alicloud_ecs_ram_role_attachment" "rally" {
  count         = var.ram_role_name != "" ? 1 : 0
  instance_id   = alicloud_instance.rally.id
  ram_role_name = var.ram_role_name
}
