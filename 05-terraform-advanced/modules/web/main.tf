# 模块：一台 web VM + 一条 firewall（练习 4 资源的可复用版）
# 模块自己不写 provider，用调用方传进来的 —— 这让它可以在任何环境里复用

resource "google_compute_instance" "web" {
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone

  # 练习 4 的教训：不写这个，改机型会被拒
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  tags = ["http-server"]

  metadata = {
    enable-oslogin = "TRUE"
  }
}

resource "google_compute_firewall" "web" {
  name    = var.firewall_name
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  target_tags   = ["http-server"]
  source_ranges = ["0.0.0.0/0"]
}
