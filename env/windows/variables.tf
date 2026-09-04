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

variable "vm_name" {
  type    = string
  default = "windows-workstation"
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
  description = "Enable QEMU guest agent channel. Flip to true only after virtio guest tools are installed in Windows."
  type        = bool
  default     = false
}

variable "iso_file_id" {
  description = <<-EOT
    Volume ID of an ISO to mount in the (empty) CD drive. null keeps the drive
    empty — set it back to "local:iso/Win10_22H2_Russian_x64v1.iso" only for a
    from-scratch reinstall.
  EOT
  type        = string
  default     = null
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
    x-vga on the GTX 950 — primary display on the physical monitor(s).
    Default true now that Windows + the NVIDIA driver are installed. Set to
    false only for a from-scratch reinstall: OVMF has no GOP for this card, so
    with x-vga the OVMF/installer screen is blind — you need the emulated std
    VGA primary and the noVNC console until the NVIDIA driver is in.
  EOT
  type        = bool
  default     = true
}
