output "vm_id" {
  value = proxmox_virtual_environment_vm.this.id
}

output "pci_mappings" {
  description = "Cluster hardware-mapping name -> node PCI path for each passed-through device."
  value       = { for k, m in proxmox_hardware_mapping_pci.this : k => one(m.map).path }
}
