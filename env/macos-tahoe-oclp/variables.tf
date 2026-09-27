variable "proxmox_node" {
  description = "bare-pve -- the GPU-passthrough node shared with env/windows, env/ubuntu, and env/macos-tahoe-desktop, arbitrated by scripts/gpu-arbiter.sh."
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
  description = <<-EOT
    Deliberately NOT scripts/gpu-arbiter.sh's MACOS_NAME ("macos-workstation"
    -- that's env/macos-tahoe-desktop's VM 103, left running its own High
    Sierra install as a frozen diagnostic state, see that env's README). This
    guest is intentionally unmanaged by the arbiter's automatic pre-start
    hook (vm_role() won't match either WIN_NAME or MACOS_NAME -> hook_prestart
    logs "not an arbiter-managed guest" and no-ops, allowing a manual start).
    GPU/USB/audio binding is still done through the SAME arbiter, just
    manually: `scripts/gpu-arbiter.sh switch macos` (rebinds devices to
    vfio-pci) before `qm start <this vmid>` -- vfio-pci binding is host-level,
    not tied to which VMID actually opens the device.
  EOT
  type    = string
  default = "macos-tahoe-oclp"
}

variable "cores" {
  description = "bare-pve's i5-4460 has exactly 4 threads, no SMT."
  type        = number
  default     = 4
}

variable "memory" {
  description = "MiB. Matches every other guest on this node -- all mutually exclusive, never run concurrently."
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
    Volume ID of a pre-built OpenCore boot ISO already uploaded to bare-pve.
    The original Tahoe EFI build from before the High Sierra pivot is still
    on the node: "local:iso/OpenCore-Tahoe-GPU.iso". Required -- no default,
    since the AMFIPass/SecureBootModel=Disable/csr-active-config changes this
    env needs (see README) mean the config.plist will diverge from that
    original build fairly quickly.
  EOT
  type        = string
}

variable "installer_image_file_id" {
  description = "Volume ID of a raw macOS recovery/BaseSystem image to import as an install disk. null once macOS is installed."
  type        = string
  default     = null
}

variable "mac" {
  description = "Distinct from every other guest in this repo (env/windows BC:24:11:F9:5D:82, env/ubuntu BC:24:11:AB:CD:01, macos-tahoe-headless BC:24:11:7A:04:0E, macos-tahoe-desktop BC:24:11:5A:C0:5E)."
  type        = string
  default     = "BC:24:11:6F:31:D9"
}

variable "gpu_primary" {
  description = <<-EOT
    x-vga on the passed-through GTX 950. false while installing (std VGA /
    noVNC console), true only once actually testing real physical output --
    see env/macos-tahoe-desktop/README.md's High Sierra section for how
    little this setting actually changes about the underlying hang once the
    driver is what's stuck (same hang signature with x-vga=1 as x-vga=0).
  EOT
  type        = bool
  default     = false
}

variable "gpu_rom_file" {
  description = "Optional vBIOS filename under /usr/share/kvm/ on the node. null = card's own stock legacy VBIOS (rombar=1) -- see env/macos-tahoe-desktop/README.md, not needed once the ACPI-hotplug args fix is applied."
  type        = string
  default     = null
}
