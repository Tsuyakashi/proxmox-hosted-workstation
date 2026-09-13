variable "proxmox_node" {
  description = "Target Proxmox node -- pve-rog, not bare-pve. A different node from env/windows and env/ubuntu, no shared GPU, no gpu-arbiter involvement."
  type        = string
  default     = "pve-rog"
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
  default = "macos-tahoe-headless"
}

variable "cores" {
  description = "pve-rog's i7-4700HQ has 8 threads total -- leave headroom for the host and other guests on the node."
  type        = number
  default     = 6
}

variable "memory" {
  description = <<-EOT
    MiB, hard reservation (no balloon -- see mod/vm-headless). pve-rog has
    ~23.38 GiB total with ~4 GiB already used by other guests -> ~16288 MiB
    here leaves roughly 3.5 GiB free for the host and everything else. Lower
    this if pve-rog gets tight; Xcode clean builds + simulators want as much
    as the node can spare.
  EOT
  type        = number
  default     = 16288
}

variable "disk_size" {
  description = <<-EOT
    GiB, thin-provisioned ceiling on pve-rog's LVM-thin pool (337.9G total,
    ~30G already used elsewhere) -- not reserved upfront, growable later.
    macOS base (~15-20G) + Xcode w/ SDKs + simulators (~20-40G) + DerivedData/
    build caches (manually cleared, not expected to grow unbounded).
  EOT
  type        = number
  default     = 100
}

variable "opencore_iso_file_id" {
  description = <<-EOT
    Volume ID of a pre-built OpenCore boot ISO already uploaded to pve-rog,
    e.g. "local:iso/OpenCore-Tahoe.iso". No default -- see the README's
    "Установка macOS Tahoe с нуля" for how to build/upload one. Required.
  EOT
  type        = string
}

variable "installer_image_file_id" {
  description = "Volume ID of a raw macOS recovery/BaseSystem image to import as an install disk (see mod/vm-headless). null once macOS is installed."
  type        = string
  default     = null
}

variable "mac" {
  description = "Distinct from every other guest in this repo (env/windows BC:24:11:F9:5D:82, env/ubuntu BC:24:11:AB:CD:01)."
  type        = string
  default     = "BC:24:11:7A:04:0E"
}

variable "network_model" {
  type    = string
  default = "vmxnet3"
}
