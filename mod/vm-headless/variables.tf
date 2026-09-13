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
  description = <<-EOT
    Dedicated RAM in MiB. No `floating` value is exposed by this module on
    purpose -> the provider never emits a balloon target, so Proxmox never
    attaches a driven virtio-balloon device. macOS ships no balloon driver
    (Apple never wrote one), so this isn't a feature this guest could use
    even if enabled -- every MiB here is a hard reservation on the node.
  EOT
  type        = number
  default     = 512
}

variable "cpu_type" {
  description = <<-EOT
    Base Proxmox `cpu:` model. Cosmetic more than functional here: `kvm_arguments`
    appends a second, more specific `-cpu host,vendor=GenuineIntel,...` to the
    actual QEMU command line, and QEMU keeps the *last* `-cpu` it parses -- that
    one wins. Kept as "host" so the two never meaningfully disagree.
  EOT
  type        = string
  default     = "host"
}

variable "agent_enabled" {
  description = "QEMU guest agent channel. No stock macOS build speaks it -- leave false unless a community qemu-ga port is installed in-guest."
  type        = bool
  default     = false
}

variable "on_boot" {
  type    = bool
  default = false
}

variable "datastore_id_disk" {
  type    = string
  default = "local-lvm"
}

variable "disk_interface" {
  description = "Interface for the persistent macOS data disk."
  type        = string
  default     = "sata0"
}

variable "disk_size" {
  description = "GiB. Thin-provisioned ceiling on LVM-thin storage, not an upfront reservation -- growable later with `apply` and no VM recreate."
  type        = number
  default     = 100
}

variable "cdrom_interface" {
  description = "Interface for the OpenCore boot ISO. Must not collide with disk_interface / installer_interface."
  type        = string
  default     = "ide0"
}

variable "opencore_iso_file_id" {
  description = <<-EOT
    Volume ID of an already-uploaded OpenCore boot ISO, e.g.
    "local:iso/OpenCore-Tahoe.iso". This is the actual bootloader -- attached
    every boot, not just for install. No default: building/uploading it is a
    manual, iterative step (see the env README), not something this module
    can assume exists.
  EOT
  type        = string
}

variable "installer_interface" {
  description = "Interface for the optional macOS recovery/BaseSystem install disk."
  type        = string
  default     = "sata1"
}

variable "installer_image_file_id" {
  description = <<-EOT
    Volume ID of a raw macOS recovery/BaseSystem image to import as an install
    disk, e.g. "local:import/BaseSystem.img" (fetched via OSX-KVM's
    macrecovery.py or similar -- there is no direct Apple-hosted installer ISO).
    null (default) omits the disk entirely -- unset it again once macOS is
    installed on the main disk; the import is a one-time copy at create time,
    not a live mount, so there's nothing to keep attached afterward.
  EOT
  type        = string
  default     = null
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "mac" {
  type = string
}

variable "network_model" {
  description = "vmxnet3 has a native in-box macOS driver (no kext) and is the current community-recommended NIC for QEMU macOS guests -- e1000 also works natively if vmxnet3 gives trouble."
  type        = string
  default     = "vmxnet3"
}

variable "os_type" {
  description = "Proxmox has no macOS ostype -- \"other\" is the standard choice in every hackintosh-on-Proxmox guide."
  type        = string
  default     = "other"
}

variable "vga_type" {
  description = "Emulated framebuffer only -- no Metal/GPU acceleration. \"std\" is the safe default; \"qxl\" is a documented alternative."
  type        = string
  default     = "std"
}

variable "tablet_device" {
  description = "USB tablet for absolute pointer positioning over VNC/Screen Sharing."
  type        = bool
  default     = true
}

variable "kvm_arguments" {
  description = <<-EOT
    Raw QEMU command-line additions OpenCore/XNU need that no Proxmox VM
    attribute expresses: the SMC device (with the OSK string every OSX-KVM/
    OpenCore guide uses -- it's a public placeholder, not a real Mac's key),
    a spoofed SMBIOS type 2, USB HID devices, and the -cpu override that adds
    vendor=GenuineIntel/+invtsc/+hypervisor/vmware-cpuid-freq=on on top of
    `host` (passes through the real Haswell instruction set, incl. AVX2,
    rather than emulating a named CPU model that might not include it).

    Sourced from current (2025/2026) Proxmox+macOS-Tahoe community guides
    (e.g. archy.net's "Installing macOS Tahoma as a Proxmox VM") -- treat as
    a verified-elsewhere starting point, not a guarantee for this exact
    node/CPU stepping. See the env README's "Известные ограничения".
  EOT
  type        = string
  default     = "-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc -smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on"
}

variable "efi_pre_enrolled_keys" {
  description = "Must stay false -- OpenCore is unsigned and Secure Boot with enrolled Microsoft/Proxmox keys would refuse to run it."
  type        = bool
  default     = false
}
