variable "name" {
  description = "Container hostname / display name."
  type        = string
}

variable "node_name" {
  type = string
}

variable "vm_id" {
  description = "Explicit CTID. null = let Proxmox pick the next free id."
  type        = number
  default     = null
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  description = "RAM in MiB."
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap in MiB. 0 disables it (fine for a desktop CT backed by host RAM)."
  type        = number
  default     = 0
}

variable "unprivileged" {
  description = <<-EOT
    Unprivileged container (root maps to an unprivileged host uid). Keep true —
    GPU device nodes are handed in with mode 0666 via `device_passthrough`, which
    is enough for an unprivileged CT to open them. Flip to false only if some
    device stubbornly needs a real root owner inside the CT.
  EOT
  type        = bool
  default     = true
}

variable "template_file_id" {
  description = <<-EOT
    Volume id of the LXC template (NOT a cloud image — a plain rootfs tarball).
    Grab one with, on the node:
      pveam update && pveam available --section system | grep ubuntu
      pveam download local ubuntu-26.04-standard_26.04-1_amd64.tar.zst
    then reference it as local:vztmpl/<file>.
  EOT
  type        = string
}

variable "os_type" {
  description = "Guest distro family for Proxmox's CT tooling (ubuntu, debian, ...)."
  type        = string
  default     = "ubuntu"
}

variable "datastore_id_rootfs" {
  description = "Datastore for the container rootfs."
  type        = string
  default     = "local-lvm"
}

variable "disk_size" {
  description = "rootfs size in GiB."
  type        = number
  default     = 32
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "mac" {
  description = "Must differ from every other guest on the bridge."
  type        = string
  default     = null
}

variable "ipv4_address" {
  description = "\"dhcp\" or CIDR (e.g. 192.168.100.41/24)."
  type        = string
  default     = "dhcp"
}

variable "ipv4_gateway" {
  description = "Only used when ipv4_address is a static CIDR."
  type        = string
  default     = null
}

variable "nameservers" {
  description = "Resolver list for the CT. null = inherit the node's."
  type        = list(string)
  default     = null
}

variable "search_domain" {
  type    = string
  default = null
}

variable "nesting" {
  description = "features.nesting — required for systemd, a display manager and nested containers/flatpak inside the CT."
  type        = bool
  default     = true
}

variable "keyctl" {
  description = "features.keyctl — systemd user sessions / gnome-keyring want it."
  type        = bool
  default     = true
}

variable "fuse" {
  description = "features.fuse — AppImage, gvfs, some Flatpak runtimes."
  type        = bool
  default     = true
}

variable "mount_feature" {
  description = "features.mount — filesystem types the CT may mount itself (e.g. [\"nfs\", \"cifs\"])."
  type        = list(string)
  default     = []
}

variable "start_on_boot" {
  type    = bool
  default = true
}

variable "startup_order" {
  description = "Boot order slot. null = unset."
  type        = number
  default     = null
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "ssh_public_keys" {
  description = "Authorized keys for root inside the CT."
  type        = list(string)
  default     = []
}

variable "password" {
  description = "root password inside the CT (optional; key auth preferred)."
  type        = string
  default     = null
  sensitive   = true
}

variable "hook_script_file_id" {
  description = "Volume id of a Proxmox hookscript (snippets), e.g. local:snippets/ct-hook.sh."
  type        = string
  default     = null
}

variable "device_passthrough" {
  description = <<-EOT
    Host device nodes to expose inside the CT (Proxmox `dev[n]:` entries — the
    LXC analogue of PCI passthrough: no vfio, the CT shares the host kernel
    driver). For an NVIDIA GPU the host must be running the NVIDIA driver (NOT
    vfio-pci) so these nodes exist:

      /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
      /dev/nvidia-modeset /dev/dri/card0 /dev/dri/renderD128

      path       - absolute host path to the device node
      mode       - octal perms Proxmox sets on the in-CT node (0666 lets an
                   unprivileged CT open it without idmap games)
      deny_write - read-only exposure
      uid / gid  - owner of the in-CT node (CT-namespace ids)
  EOT
  type = list(object({
    path       = string
    mode       = optional(string, "0666")
    deny_write = optional(bool, false)
    uid        = optional(number)
    gid        = optional(number)
  }))
  default = []
}

variable "mount_points" {
  description = <<-EOT
    Extra mount points. For a host bind mount set `volume` to a host path
    (needs unprivileged-CT idmap awareness for writes); for a Proxmox volume
    set it to <datastore>:<size-in-GiB> or an existing volume id.
  EOT
  type = list(object({
    volume        = string
    path          = string
    size          = optional(string)
    read_only     = optional(bool, false)
    acl           = optional(bool)
    backup        = optional(bool, false)
    mount_options = optional(list(string))
  }))
  default = []
}
