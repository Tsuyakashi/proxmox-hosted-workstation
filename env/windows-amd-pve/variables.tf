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
  type    = string
  default = "windows-workstation"
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
    Installer ISO on amd-pve's OWN local storage (node-local, not shared):
      scp Win10_22H2_Russian_x64v1.iso amd-pve:/var/lib/vz/template/iso/
    Set to null after install to empty the drive.
  EOT
  type        = string
  default     = null
  # default   = "local:iso/Win10_22H2_Russian_x64v1.iso"
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
    x-vga on the GTX 950. false for install: OVMF has no GOP for this card,
    so with x-vga the installer is blind — std VGA + noVNC until the NVIDIA
    driver is in. Then flip to true and `qm stop && qm start`.
  EOT
  type        = bool
  default     = true
}
