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

variable "ct_name" {
  type    = string
  default = "ubuntu-workstation"
}

variable "cores" {
  type    = number
  default = 4
}

variable "memory" {
  description = "RAM in MiB. Matches env/windows (they never run at the same time)."
  type        = number
  default     = 12288
}

variable "swap" {
  type    = number
  default = 0
}

variable "unprivileged" {
  description = "Keep true; the GPU nodes come in at mode 0666. See mod/ct."
  type        = bool
  default     = true
}

variable "template_file_id" {
  description = <<-EOT
    LXC template volume id (a minimal rootfs tarball, not a cloud image).
    On the node:
      pveam update
      pveam available --section system | grep ubuntu
      pveam download local ubuntu-26.04-standard_26.04-1_amd64.tar.zst
    Adjust the exact filename to whatever `pveam available` lists.
  EOT
  type        = string
  default     = "local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
}

variable "disk_size" {
  description = "rootfs GiB. A full GNOME + NVIDIA userspace + toolchain needs ~15 GiB; 40 leaves headroom."
  type        = number
  default     = 40
}

variable "mac" {
  description = "Differs from every other guest on vmbr0 (env/windows uses BC:24:11:F9:5D:82)."
  type        = string
  default     = "BC:24:11:AB:CD:01"
}

variable "ipv4_address" {
  description = "\"dhcp\" or a static CIDR."
  type        = string
  default     = "dhcp"
}

variable "ipv4_gateway" {
  type    = string
  default = null
}

variable "ssh_public_keys" {
  description = "Authorized keys for root in the CT (console login also works via `pct enter`)."
  type        = list(string)
  default     = []
}

variable "hook_script_file_id" {
  description = <<-EOT
    Proxmox hookscript volume id — the GPU arbiter's pre-start phase. Install
    the file first with scripts/install-gpu-arbiter.sh (it is not uploaded by
    Terraform: bpg only does snippets over SSH). null = no hookscript.
  EOT
  type        = string
  default     = "local:snippets/gpu-arbiter.sh"
}
