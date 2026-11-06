output "env_name" {
  value = local.env
}

output "instance_ip" {
  value = module.web.instance_ip
}

output "ssh_hint" {
  value = module.web.ssh_hint
}
