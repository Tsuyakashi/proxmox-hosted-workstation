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
  description = <<-EOT
    FALSE = privileged. A full Ubuntu GNOME / GDM desktop needs a real
    systemd-logind graphical session + seat + working udev, which an
    unprivileged Proxmox CT does not give. See mod/ct's `unprivileged` for the
    trade-off (container root == host root on the shared kernel; accepted here
    for a single-user workstation whose Windows half is an isolated VM).
  EOT
  type        = bool
  default     = false
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
  description = "rootfs GiB. Full ubuntu-desktop + snap + NVIDIA userspace + Steam/Discord/Chrome/VS Code + a game or two -> 64."
  type        = number
  default     = 64
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

variable "nameservers" {
  description = <<-EOT
    Resolvers for the CT. Must NOT inherit bare-pve's own resolv.conf — it
    points at Tailscale MagicDNS (100.100.100.100), unreachable from a
    non-Tailscale container.
  EOT
  type        = list(string)
  default     = ["192.168.100.1", "8.8.8.8", "1.1.1.1"]
}

variable "ssh_public_keys" {
  description = "Authorized keys for root in the CT (console login also works via `pct enter`)."
  type        = list(string)
  default     = []
}

# NOTE: hook_script_file_id and device_passthrough are intentionally NOT passed
# to mod/ct here — Proxmox restricts both to root@pam, so the API token 403s.
# scripts/lxc-ct-passthrough.sh sets them on the node as root instead.
