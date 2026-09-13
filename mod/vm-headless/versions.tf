terraform {
  required_version = ">= 1.16.1"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.112.0" # kvm_arguments (full -cpu/-device override) needs this
    }
  }
}
