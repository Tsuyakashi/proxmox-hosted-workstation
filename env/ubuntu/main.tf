# Ubuntu 26.04 desktop workstation on bare-pve.
#
# This env owns the cluster PCI mappings (manage_mappings = true). env/windows
# targets the same physical devices, so the two are MUTUALLY EXCLUSIVE — only
# one may be applied at a time; whichever is applied owns the mappings.
#
# Booting: OVMF has no GOP for the GTX 950 (no UEFI vBIOS), so the physical
# monitor stays dark through OVMF/GRUB. The in-tree nouveau driver lights it
# up once KMS initialises — no Code 43 games, unlike Windows. Keyboard/mouse
# come from the passed-through USB controllers.

module "ubuntu_vm" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  providers = {
    proxmox      = proxmox
    proxmox.root = proxmox.root
  }

  cores          = var.cores
  memory         = var.memory
  mac            = var.mac
  os_type        = var.os_type
  agent_enabled  = var.agent_enabled
  iso_file_id    = var.iso_file_id
  disk_interface = "scsi0"
  disk_size      = 64
  network_model  = "virtio"

  passthrough = [
    {
      name         = "gtx950"
      path         = "0000:01:00"
      id           = "10de:1402"
      subsystem_id = "10de:1402"
      iommu_group  = 1
      primary_gpu  = true
    },
    {
      name         = "usb-xhci"
      path         = "0000:00:14.0"
      id           = "8086:8c31"
      subsystem_id = "1849:8c31"
      iommu_group  = 2
    },
    {
      name         = "usb-ehci1"
      path         = "0000:00:1d.0"
      id           = "8086:8c26"
      subsystem_id = "1849:8c26"
      iommu_group  = 8
    },
    {
      name         = "usb-ehci2"
      path         = "0000:00:1a.0"
      id           = "8086:8c2d"
      subsystem_id = "1849:8c2d"
      iommu_group  = 4
    },
    {
      name         = "onboard-audio"
      path         = "0000:00:1b.0"
      id           = "8086:8c20"
      subsystem_id = "1849:7662"
      iommu_group  = 5
    },
  ]
}
