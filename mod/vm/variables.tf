variable "name" {
  type = string
}

variable "node_name" {
  type = string
}

variable "cores" {
  type    = number
  default = 1
}

variable "memory" {
  type    = number
  default = 512
}

variable "cpu_type" {
  description = <<-EOT
    Emulated CPU model. Use "host" for a passthrough workstation — "qemu64"/"kvm64"
    lack SSE4/AES and cripple Windows. Proxmox auto-adds the NVIDIA Code 43 hide
    (kvm=off, hv_vendor_id) when os_type is a Windows type, so no custom args are
    needed for Maxwell/Pascal in the common case.
  EOT
  type        = string
  default     = "host"
}

variable "agent_enabled" {
  description = <<-EOT
    Enable the QEMU guest agent channel. Keep false until the virtio guest tools
    are installed in Windows — otherwise every shutdown waits ~3 min for an agent
    that never answers.
  EOT
  type        = bool
  default     = false
}

variable "datastore_id_disk" {
  description = "Datastore для диска VM."
  type        = string
  default     = "local-lvm"
}

variable "disk_interface" {
  description = "sata0 for Windows (built-in driver, no install-time virtio), scsi0 for Linux."
  type        = string
  default     = "sata0"
}

variable "disk_size" {
  type    = number
  default = 10
}

variable "cdrom_interface" {
  description = "Interface slot for the install ISO. Must not collide with disk_interface."
  type        = string
  default     = "ide3"
}

variable "iso_file_id" {
  description = "Volume ID of an already-uploaded ISO, e.g. local:iso/Win10_22H2_Russian_x64v1.iso. null = empty drive."
  type        = string
  default     = null
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "mac" {
  type    = string
  default = "BC:24:11:F9:5D:82"
}

variable "network_model" {
  description = "e1000 works in the Windows installer out of the box; virtio needs the virtio-win ISO."
  type        = string
  default     = "e1000"
}

variable "os_type" {
  description = "l26 - Linux, win10/win11 - Windows. Windows types make Proxmox add the hyperv enlightenments + Code 43 hide."
  type        = string
  default     = "win10"
}

variable "passthrough" {
  description = <<-EOT
    Whole PCI devices to hand to the guest, in order — entry N becomes hostpciN.
    Each device gets its own cluster hardware mapping (created via the root@pam
    provider alias). Pass the function-less path ("0000:01:00") to forward every
    function of a multi-function device (GPU + its HDMI audio, etc.).

      name         - hardware mapping alias (cluster-unique)
      path         - PCI path; function-less = all functions
      id           - vendor:device of the primary function
      subsystem_id - subsystem vendor:device (lspci -vnn -s <addr> | grep -i subsystem)
      iommu_group  - IOMMU group number (readlink -f /sys/bus/pci/devices/0000:<addr>/iommu_group)
      primary_gpu  - true on exactly one entry -> x-vga=1 (guest primary display,
                     disables the Proxmox VNC console, output goes to serial + the
                     physical monitor on that card)
      rom_file     - optional vBIOS file under /usr/share/kvm/ on the node; set this
                     if the monitor stays dark at the OVMF screen (primary-card ROM
                     shadowed by host POST)
  EOT
  type = list(object({
    name         = string
    path         = string
    id           = string
    subsystem_id = optional(string)
    iommu_group  = optional(number)
    primary_gpu  = optional(bool, false)
    rom_file     = optional(string)
  }))
  default = []

  validation {
    condition     = length([for d in var.passthrough : d if d.primary_gpu]) <= 1
    error_message = "At most one passthrough entry may set primary_gpu = true."
  }
}

variable "usb_devices" {
  description = <<-EOT
    Individual USB devices to forward by id/port — normally unnecessary when a whole
    USB controller is in `passthrough`. Kept as an escape hatch.
  EOT
  type = list(object({
    host = string
    usb3 = optional(bool, true)
  }))
  default = []
}
