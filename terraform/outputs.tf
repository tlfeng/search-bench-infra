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
