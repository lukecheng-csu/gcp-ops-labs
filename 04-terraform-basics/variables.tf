variable "project_id" {
  description = "GCP 项目 ID"
  type        = string
  default     = "lukechengtest"
}

variable "region" {
  description = "区域（e2-micro 免费额度限 us-west1/us-central1/us-east1）"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "vm_name" {
  description = "新 VM 名。带 -tf 后缀避开练习 1 手搓的 practice-web"
  type        = string
  default     = "practice-web-tf"
}

variable "machine_type" {
  type    = string
  default = "e2-micro"
}

variable "firewall_name" {
  type    = string
  default = "practice-web-tf-allow-http"
}
