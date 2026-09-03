module "minimal_vm" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  providers = {
    proxmox      = proxmox
    proxmox.root = proxmox.root
  }

  cores  = var.cores
  memory = var.memory

  iso_file_id = "local:iso/Win10_22H2_Russian_x64v1.iso"

  gpu_devices = [
    { path = "0000:01:00.0", id = "10de:1402", iommu_group = 1, subsystem_id = "10de:1402" },
    { path = "0000:01:00.1", id = "10de:0fba", iommu_group = 1, subsystem_id = "10de:1402" },
  ]
}
