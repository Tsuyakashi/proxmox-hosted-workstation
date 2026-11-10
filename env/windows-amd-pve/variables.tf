variable "proxmox_node" {
  description = "Target Proxmox node"
  type        = string
  default     = "amd-pve"
}

variable "proxmox_endpoints" {
  type = map(string)
  default = {
    "bare-pve" = "https://192.168.100.30:8006/"
    "pve-rog"  = "https://192.168.100.20:8006/"
    "amd-pve"  = "https://192.168.100.40:8006/"
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
  description = "Must match WIN_NAME in gpu-arbiter.sh (default windows-workstation)."
  type        = string
  default     = "windows-workstation"
}

variable "cores" {
  description = "AMD A4-5300 has exactly 2 threads."
  type        = number
  default     = 2
}

variable "memory" {
  description = "MiB. amd-pve has ~15.5 GiB; leave the host ~5 GiB."
  type        = number
  default     = 10240
}

variable "agent_enabled" {
  description = "Enable QEMU guest agent channel. Flip to true only after virtio guest tools are installed in Windows."
  type        = bool
  default     = false
}

variable "iso_file_id" {
  description = <<-EOT
    Installer ISO on amd-pve's OWN local storage (node-local, not shared).
    null = empty drive (installed state). For a from-scratch reinstall:
      scp Win10_22H2_Russian_x64v1.iso amd-pve:/var/lib/vz/template/iso/
      terraform apply -var iso_file_id=local:iso/Win10_22H2_Russian_x64v1.iso -var gpu_primary=false
    Note: -var passes strings literally — "null" on the CLI is the string
    "null", not null; leave the var unset instead.
  EOT
  type        = string
  default     = null
}

variable "mac" {
  description = "Distinct from env/windows on bare-pve (BC:24:11:F9:5D:82) — same L2."
  type        = string
  default     = "BC:24:11:A3:7D:41"
}

variable "os_type" {
  type    = string
  default = "win10"
}

variable "gpu_primary" {
  description = <<-EOT
    x-vga on the GTX 950 — primary display on the physical monitor.
    Default true: Windows + NVIDIA driver are installed. Set false only for a
    from-scratch reinstall: the card has no UEFI GOP, so with x-vga the
    OVMF/installer screen is blind — std VGA + noVNC until the NVIDIA driver
    is in. Changing it needs a full QEMU restart (qm shutdown && qm start),
    not a guest reboot.
  EOT
  type        = bool
  default     = true
}
