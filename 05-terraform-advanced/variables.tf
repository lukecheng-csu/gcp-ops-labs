variable "project_id" {
  type    = string
  default = "lukechengtest"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

# 两个 workspace 同时跑时注意：免费额度只有 1 台 e2-micro，
# dev+prod 同时挂着会有一台计费（约 $0.008/小时），练完记得拆
variable "machine_type" {
  type    = string
  default = "e2-micro"
}
