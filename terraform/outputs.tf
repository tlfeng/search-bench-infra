output "stack" {
  description = "当前环境切片键；default 表示未切片（资源名无后缀）"
  value       = var.stack
}

output "name_prefix" {
  description = "资源名前缀，多栈并存时用它辨认这套环境属于哪个 stack"
  value       = local.name_prefix
}

# ---------- 档位目录（纯配置，不依赖任何资源） ----------
# 给 scripts/bench-matrix.sh 做并发前的库存/规格预检用。
# 刻意从 terraform 的 locals 导出而不是在 bash 里抄一份映射 ——
# 抄一份就意味着「改档位忘了改脚本」，最终会拿着错的机型去做库存检查。
output "profile_catalog" {
  description = "全部档位 -> ES 侧架构/规格档/机型，脚本据此做预检"
  value       = { for k, v in local.es_by_profile : k => { arch = v.arch, size = v.size, type = v.type } }
}

output "rally_catalog" {
  description = "rally 侧 <架构>-<规格档> -> 机型"
  value       = { for k, v in local.rally_by_key : k => v.type }
}

output "es_private_ips" {
  description = "ES 节点内网 IP，压测目标地址"
  value       = [for i in alicloud_instance.es : i.private_ip]
}

output "es_public_ips" {
  description = "ES 节点公网 IP（未分配则为空）"
  value       = [for i in alicloud_instance.es : i.public_ip]
}

output "rally_public_ip" {
  description = "rally 客户端公网 IP，压测入口"
  value       = alicloud_instance.rally.public_ip
}

output "rally_private_ip" {
  value = alicloud_instance.rally.private_ip
}

output "target_hosts" {
  description = "直接可用于 esrally --target-hosts 的字符串"
  value       = join(",", [for i in alicloud_instance.es : "http://${i.private_ip}:9200"])
}

output "vpc_id" { value = alicloud_vpc.this.id }
output "vswitch_id" { value = alicloud_vswitch.this.id }

output "oss_bucket" { value = var.oss_bucket }
output "oss_prefix" { value = var.oss_prefix }

output "profile" {
  description = "当前生效的档位及其机型/架构组合"
  value = {
    name       = var.profile
    es_arch    = local.prof.arch
    es_type    = local.prof.es_instance_type
    rally_arch = local.prof.rally_arch
    rally_type = local.prof.rally_instance_type
  }
}

output "billing" {
  description = "当前生效的计费方式；spot=竞价（可能被回收），postpaid=按量"
  value = {
    es    = local.es_use_spot ? "spot" : "postpaid"
    rally = local.rally_use_spot ? "spot" : "postpaid"
  }
}

output "ssh_hint" {
  description = "登录提示"
  value       = "ssh -i <私钥> root@${alicloud_instance.rally.public_ip}"
}
