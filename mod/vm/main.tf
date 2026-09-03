locals {
  gpu_map = [
    for dev in var.gpu_devices : {
      node         = var.node_name
      path         = dev.path
      id           = dev.id
      iommu_group  = dev.iommu_group
      subsystem_id = dev.subsystem_id
    }
  ]
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
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
    file_id = var.iso_file_id
  }

  boot_order = var.boot_order

  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac
    model       = var.network_model
  }

  machine = "q35"
  bios    = "ovmf"

  serial_device {}

  hostpci {
    device  = "hostpci0"
    mapping = proxmox_hardware_mapping_pci.this.name
    pcie    = true
    rombar  = true
    xvga    = true
  }

  operating_system {
    type = var.os_type
  }
}

resource "proxmox_hardware_mapping_pci" "this" {
  provider = proxmox.root

  name = var.gpu_name
  map  = local.gpu_map
}