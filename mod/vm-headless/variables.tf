variable "name" {
  type = string
}

variable "node_name" {
  type = string
}

variable "cores" {
  description = <<-EOT
    Cores per socket. macOS's CPU-topology parsing wants a power-of-2 core
    count -- for any other total, split it across `sockets` instead of
    raising this alone (e.g. 6 total -> cores=2, sockets=3, not cores=6).
    See LongQT-sea/OpenCore-ISO's CPU section for the general table.
  EOT
  type        = number
  default     = 1
}

variable "sockets" {
  description = "See `cores` -- total vCPUs is cores * sockets."
  type        = number
  default     = 1
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
    appends a second, more specific `-cpu` to the actual QEMU command line, and
    QEMU keeps the *last* `-cpu` it parses -- that one wins. Kept as "host" so
    the two never meaningfully disagree; see `kvm_arguments` for why the real
    override is a named model, not `host` passthrough.
  EOT
  type        = string
  default     = "host"
}

variable "agent_enabled" {
  description = <<-EOT
    QEMU guest agent channel. Stock macOS has no built-in qemu-ga -- leave
    false (same footgun as env/windows: Proxmox waits out a timeout on
    every shutdown for an agent that never answers) unless/until a
    community qemu-ga port is actually installed in-guest. LongQT-sea/
    OpenCore-ISO recommends enabling this for macOS 10.14-26, but that
    assumes such a port is present -- it isn't, here, yet.
  EOT
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
  description = "virtio -- LongQT-sea/OpenCore-ISO's current guidance for macOS 11-26 (their OpenCore build carries the kext virtio networking needs). vmxnet3/e1000 are older-macOS fallbacks, not preferred here."
  type        = string
  default     = "virtio"
}

variable "os_type" {
  description = "Proxmox has no macOS ostype. l26 (\"Linux\") -- LongQT-sea/OpenCore-ISO's explicit recommendation (affects Proxmox's own RTC/clock defaults, not something macOS itself reads) -- not \"other\"."
  type        = string
  default     = "l26"
}

variable "vga_type" {
  description = "Emulated framebuffer only -- no Metal/GPU acceleration. \"std\" is the safe default; \"qxl\" is a documented alternative."
  type        = string
  default     = "std"
}

variable "kvm_arguments" {
  description = <<-EOT
    Raw QEMU command-line additions OpenCore/XNU need that no Proxmox VM
    attribute expresses: the SMC device (with the OSK string every OSX-KVM/
    OpenCore guide uses -- it's a public placeholder, not a real Mac's key),
    a spoofed SMBIOS type 2, USB HID devices (usb-kbd/virtio-tablet -- only
    matter for the OpenCore picker/Recovery/Setup Assistant over VNC; once
    SSH is set up they just sit idle, not worth splitting into a separate
    install-time-only argument set), and the -cpu override.

    -cpu is a *named* model (Skylake-Client-v4), not `host` passthrough,
    following LongQT-sea/OpenCore-ISO's explicit current guidance: `host`
    is measurably slower under macOS (~30-44%, their own benchmark link)
    and is exactly what that project exists to avoid. Skylake-Client-v4 (no
    AVX-512) matches this node's real Haswell ceiling -- do NOT switch to
    the AVX-512 Skylake-Server-v4 variant they also document, the physical
    CPU doesn't have it and KVM can't fake an instruction set that isn't
    silicon. -device virtio-tablet (not usb-tablet) works around a
    documented macOS-26-specific cursor-freeze bug in the same guide.

    Sourced from LongQT-sea/OpenCore-ISO's README (actively maintained,
    explicitly covers Tahoe) -- more authoritative for this exact stack
    than the generic hackintosh guides this string was first drafted from.
    See the env README's "Известные ограничения" / "Что реально сработало".
  EOT
  type        = string
  default     = "-device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc -smbios type=2 -device qemu-xhci -device usb-kbd -device virtio-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu Skylake-Client-v4,vendor=GenuineIntel"
}

variable "efi_pre_enrolled_keys" {
  description = "Must stay false -- OpenCore is unsigned and Secure Boot with enrolled Microsoft/Proxmox keys would refuse to run it."
  type        = bool
  default     = false
}
