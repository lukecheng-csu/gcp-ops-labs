variable "vm_name" {
  type = string
}

variable "machine_type" {
  type    = string
  default = "e2-micro"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "firewall_name" {
  type = string
}
