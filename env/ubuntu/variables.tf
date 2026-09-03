variable "proxmox_node" {
  description = "Target Proxmox node"
  type        = string
  default     = "bare-pve"
}

variable "proxmox_endpoints" {
  type = map(string)
  default = {
    "bare-pve" = "https://192.168.100.30:8006/"
    "pve-rog"  = "https://192.168.100.20:8006/"
  }
}

locals {
  proxmox_endpoint = var.proxmox_endpoints[var.proxmox_node]
  node_name        = var.proxmox_node
}

variable "proxmox_insecure" {
  type    = bool
  default = true
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_root_password" {
  description = "root@pam password — needed to create the PCI hardware mappings (Vault wrapper supplies it)."
  type        = string
  sensitive   = true
}

variable "vm_name" {
  type    = string
  default = "ubuntu-workstation"
}

variable "cores" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "agent_enabled" {
  type    = bool
  default = false
}

variable "iso_file_id" {
  type    = string
  default = "local:iso/ubuntu-26.04-desktop-amd64.iso"
}

variable "mac" {
  description = "Must differ from every other VM on the bridge (env/windows uses BC:24:11:F9:5D:82)."
  type        = string
  default     = "BC:24:11:AB:CD:01"
}

variable "os_type" {
  type    = string
  default = "l26"
}
