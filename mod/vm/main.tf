# Was a single resource (one mapping, one entry per PCI function) before the
# switch to whole-device / multi-device passthrough.
moved {
  from = proxmox_hardware_mapping_pci.this
  to   = proxmox_hardware_mapping_pci.this["gtx950"]
}

# One cluster-wide hardware mapping per passed-through device.
# Creating/altering PCI mappings is restricted to root@pam by the Proxmox API
# (IOMMU interaction), hence the proxmox.root provider alias.
resource "proxmox_hardware_mapping_pci" "this" {
  provider = proxmox.root

  for_each = { for d in var.passthrough : d.name => d }

  name = each.value.name

  # Exactly one map entry for this node. Multiple entries are meant as
  # per-node alternatives for a cluster — giving two here (one per PCI
  # function) makes Proxmox forward only the first one.
  map = [
    {
      node         = var.node_name
      path         = each.value.path
      id           = each.value.id
      subsystem_id = each.value.subsystem_id
      iommu_group  = each.value.iommu_group
    }
  ]
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name

  machine = "q35"
  bios    = "ovmf"

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
  }

  agent {
    enabled = var.agent_enabled
  }

  efi_disk {
    datastore_id = var.datastore_id_disk
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.datastore_id_disk
    interface    = var.disk_interface
    size         = var.disk_size
    file_format  = "raw"
  }

  cdrom {
    file_id   = coalesce(var.iso_file_id, "none")
    interface = var.cdrom_interface
  }

  # Try the ISO first, then the installed disk. Must match the interfaces
  # actually assigned — verify with `qm config <vmid> | grep -E '^(ide|sata|boot)'`
  # after apply (the provider can move the cdrom slot).
  boot_order = [var.cdrom_interface, var.disk_interface]

  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac
    model       = var.network_model
  }

  # Whole PCI devices -> hostpci0..N in list order.
  dynamic "hostpci" {
    for_each = { for idx, d in var.passthrough : idx => d }
    content {
      device   = "hostpci${hostpci.key}"
      mapping  = proxmox_hardware_mapping_pci.this[hostpci.value.name].name
      pcie     = true
      rombar   = true
      xvga     = hostpci.value.primary_gpu
      rom_file = hostpci.value.rom_file
    }
  }

  dynamic "usb" {
    for_each = var.usb_devices
    content {
      host = usb.value.host
      usb3 = usb.value.usb3
    }
  }

  # With a primary-GPU (x-vga) device the Proxmox web console falls back to
  # this serial redirect — that is how OVMF/boot output is still reachable.
  serial_device {}

  operating_system {
    type = var.os_type
  }
}
