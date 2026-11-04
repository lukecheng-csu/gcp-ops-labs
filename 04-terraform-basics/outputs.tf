output "instance_name" {
  value = google_compute_instance.web.name
}

output "instance_ip" {
  value = google_compute_instance.web.network_interface[0].access_config[0].nat_ip
}

output "ssh_hint" {
  value = "gcloud compute ssh ${var.vm_name} --zone=${var.zone} --project=${var.project_id}"
}
