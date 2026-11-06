terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # 练习 5 核心：state 存 GCS（练习 4 的本地 state 失忆/丢备份问题在这里根治）
  # GCS backend 天带 state lock：谁在跑 apply 就锁住，第二个人进来直接报错
  backend "gcs" {
    bucket = "lukechengtest-tfstate"
    prefix = "labs/terraform-advanced"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  # workspace 名就是环境名：default/dev/prod
  env = terraform.workspace
}

# 把练习 4 的 VM + firewall 抽成可复用模块（modules/web/）
module "web" {
  source = "./modules/web"

  vm_name       = "${local.env}-practice-web"
  machine_type  = var.machine_type
  zone          = var.zone
  firewall_name = "${local.env}-practice-web-allow-http"
}
