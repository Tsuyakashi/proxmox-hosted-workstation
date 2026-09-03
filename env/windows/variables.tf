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
  default = 4096
}

variable "agent_enabled" {
  description = "Enable QEMU guest agent channel. Flip to true only after virtio guest tools are installed in Windows."
  type        = bool
  default     = false
}

variable "iso_file_id" {
  description = "Volume ID of the Windows install ISO already uploaded to the node."
  type        = string
  default     = "local:iso/Win10_22H2_Russian_x64v1.iso"
}

variable "mac" {
  type    = string
  default = "BC:24:11:F9:5D:82"
}

variable "os_type" {
  type    = string
  default = "win10"
}

variable "gpu_primary" {
  description = <<-EOT
    x-vga on the GTX 950. Keep false for the first Windows install (emulated std
    VGA primary -> noVNC console works; OVMF has no GOP for this card so x-vga
    would mean a blind install). Set true after Windows + the NVIDIA driver are
    in -> primary display moves to the physical monitor.
  EOT
  type        = bool
  default     = false
}