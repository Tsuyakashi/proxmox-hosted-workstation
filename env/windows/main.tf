module "minimal_vm" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  providers = {
    proxmox      = proxmox
    proxmox.root = proxmox.root
  }

  cores         = var.cores
  memory        = var.memory
  mac           = var.mac
  os_type       = var.os_type
  agent_enabled = var.agent_enabled
  iso_file_id   = var.iso_file_id

  # Whole-device passthrough for bare-pve: the entire GPU, all three USB
  # controllers and the onboard audio go to the guest. Only storage (SATA,
  # IOMMU group 9 — the PVE boot disk) and the Realtek NIC (group 10, vmbr0)
  # stay with the host; guest networking is virtual.
  #
  # ids / subsystem-ids / groups verified on bare-pve:
  #   lspci -nnk ; readlink -f /sys/bus/pci/devices/0000:<addr>/iommu_group
  passthrough = [
    {
      name         = "gtx950"
      path         = "0000:01:00" # function-less -> forwards 01:00.0 (VGA) + 01:00.1 (audio)
      id           = "10de:1402"
      subsystem_id = "10de:1402"
      iommu_group  = 1
      primary_gpu  = true
    },
    {
      name         = "usb-xhci" # USB 3.0, rear ports
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
      name         = "onboard-audio" # Intel HDA, line-out / mic jacks
      path         = "0000:00:1b.0"
      id           = "8086:8c20"
      subsystem_id = "1849:7662"
      iommu_group  = 5
    },
  ]
}
