variable "proxmox_node" {
  description = "Default target Proxmox node, bare-pve in default"
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
  type      = string
  sensitive = true
}

variable "vm_name" {
  type    = string
  default = "windows-workstation"
}

variable "cores" {
  type    = number
  default = 2
}


variable "memory" {
  type    = number
  default = 2048
}

variable "mac" {
  type    = string
  default = "BC:24:11:F9:5D:82"
}

variable "os_type" {
  type    = string
  default = "win10"
}