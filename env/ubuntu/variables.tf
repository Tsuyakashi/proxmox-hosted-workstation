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

variable "vm_name" {
  type    = string
  default = "ubuntu-workstation"
}

variable "cores" {
  type    = number
  default = 4
}

variable "memory" {
  description = "RAM in MiB. Matches env/windows — they never run at the same time."
  type        = number
  default     = 12288
}

variable "agent_enabled" {
  description = "QEMU guest agent. Flip true after `apt install qemu-guest-agent` in the VM."
  type        = bool
  default     = false
}

variable "iso_file_id" {
  description = <<-EOT
    Ubuntu **desktop** ISO (not the server/live-server, not an LXC template).
    Upload once: on the node,
      cd /var/lib/vz/template/iso
      wget https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso
    then set it back to null after install to unmount the drive.
  EOT
  type        = string
  default     = "local:iso/ubuntu-26.04-desktop-amd64.iso"
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

variable "gpu_primary" {
  description = <<-EOT
    x-vga on the GTX 950 — primary display on the physical monitor(s).
    Default true: nouveau lights the monitor at the installer's KMS init, so
    unlike Windows there's no blind-install phase. Set false only if you want
    the emulated VGA + noVNC console for some reason.
  EOT
  type        = bool
  default     = true
}
