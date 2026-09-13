# Headless macOS VM -- OpenCore/hackintosh, no GPU passthrough, no
# gpu-arbiter involvement. Independent of mod/vm: no hardware_mapping_pci
# resource, no hostpci block, nothing here contends for bare-pve's GPU or
# participates in scripts/gpu-arbiter.sh at all.

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  on_boot   = var.on_boot

  machine = "q35"
  bios    = "ovmf"

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
    # No `floating` -> no balloon target -> no virtio-balloon device driven.
    # Apple ships no balloon driver for macOS; this reservation is hard RAM.
  }

  agent {
    enabled = var.agent_enabled
  }

  efi_disk {
    datastore_id      = var.datastore_id_disk
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = var.efi_pre_enrolled_keys
  }

  # Persistent macOS data disk.
  disk {
    datastore_id = var.datastore_id_disk
    interface    = var.disk_interface
    size         = var.disk_size
    file_format  = "raw"
  }

  # Optional recovery/BaseSystem install media -- imported once at create
  # time (not a live mount). Unset installer_image_file_id and re-apply to
  # detach it once macOS is actually installed on the disk above.
  dynamic "disk" {
    for_each = var.installer_image_file_id != null ? [var.installer_image_file_id] : []
    content {
      datastore_id = var.datastore_id_disk
      interface    = var.installer_interface
      import_from  = disk.value
      file_format  = "raw"
    }
  }

  # OpenCore boot ISO -- the actual bootloader, attached every boot, not just
  # for install. See env README for how to build/upload it.
  cdrom {
    file_id   = var.opencore_iso_file_id
    interface = var.cdrom_interface
  }

  boot_order = [var.cdrom_interface, var.disk_interface]

  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac
    model       = var.network_model
  }

  # Software framebuffer only -- no Metal/GPU acceleration. Access is via
  # VNC/Screen Sharing over this, or SSH once the network is up.
  vga {
    type = var.vga_type
  }

  # OpenCore/XNU bits with no first-class Proxmox VM attribute -- SMC device,
  # spoofed SMBIOS type 2, USB HID, and the -cpu override. See variables.tf
  # for sourcing and caveats.
  kvm_arguments = var.kvm_arguments

  operating_system {
    type = var.os_type
  }
}
