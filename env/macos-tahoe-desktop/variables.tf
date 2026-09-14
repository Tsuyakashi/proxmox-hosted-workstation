variable "proxmox_node" {
  description = "bare-pve -- the GPU-passthrough node shared with env/windows and env/ubuntu, arbitrated by scripts/gpu-arbiter.sh."
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
  description = "Must match scripts/gpu-arbiter.sh's MACOS_NAME (default \"macos-workstation\") -- the arbiter identifies this guest by exact name match, not just \"it's a VM\"."
  type        = string
  default     = "macos-workstation"
}

variable "cores" {
  description = "bare-pve's i5-4460 has exactly 4 threads, no SMT -- 4 cores is already a power of 2 (mod/vm has no sockets split like mod/vm-headless; not needed here, unlike pve-rog which had cores to spare over a non-power-of-2 target)."
  type        = number
  default     = 4
}

variable "memory" {
  description = "MiB. Matches env/windows's 12288 -- the three guests are mutually exclusive (never run concurrently), so reusing the same full allocation is safe and leaves ~3 GiB for the host, same as windows already does."
  type        = number
  default     = 12288
}

variable "disk_size" {
  description = "GiB, thin-provisioned ceiling on local-lvm."
  type        = number
  default     = 100
}

variable "opencore_iso_file_id" {
  description = <<-EOT
    Volume ID of a pre-built OpenCore boot ISO already uploaded to bare-pve,
    e.g. "local:iso/OpenCore-Tahoe-GPU.iso". No default -- see the README's
    install-from-scratch section. Required.
  EOT
  type        = string
}

variable "installer_image_file_id" {
  description = "Volume ID of a raw macOS recovery/BaseSystem image to import as an install disk. null once macOS is installed."
  type        = string
  default     = null
}

variable "mac" {
  description = "Distinct from every other guest in this repo (env/windows BC:24:11:F9:5D:82, env/ubuntu BC:24:11:AB:CD:01, macos-tahoe-headless BC:24:11:7A:04:0E)."
  type        = string
  default     = "BC:24:11:5A:C0:5E"
}

variable "gpu_primary" {
  description = <<-EOT
    x-vga on the passed-through GTX 950 -- output to the physical monitor.
    Same install-time dance as env/windows: false while OVMF has no GOP for
    this card (std VGA / noVNC console for the installer), flip true once
    macOS + WhateverGreen are in and driving the card themselves.
  EOT
  type        = bool
  default     = false
}
