terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.111.1"
    }
  }
}

provider "proxmox" {
  endpoint  = local.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
}

provider "proxmox" {
  alias    = "root"
  endpoint = local.proxmox_endpoint
  username = "root@pam"
  password = var.proxmox_root_password
  insecure = var.proxmox_insecure
}