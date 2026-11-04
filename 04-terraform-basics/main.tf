terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- VM（对应练习 1 手搓的那台，名字带 -tf 后缀避免冲突） ---

resource "google_compute_instance" "web" {
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone

  # 改机型等操作需要停机执行；不设此项，apply 会直接报错拒绝
  # （GCE provider 的显式授权门禁：绝不悄悄停你的机器）
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
    # 空块 = 分配临时公网 IP；destroy 后 IP 不保留
    access_config {}
  }

  tags = ["http-server"]

  # 沿用练习 1 的加固思路：走 OS Login（SSH key 由 IAM 管，不散落在 metadata）
  metadata = {
    enable-oslogin = "TRUE"
  }
}

# --- Firewall：放行 80/443（对应练习 1 的 http-server 标签思路） ---

resource "google_compute_firewall" "web" {
  name    = var.firewall_name
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", ]
  }

  target_tags   = ["http-server"]
  source_ranges = ["0.0.0.0/0"]
}
