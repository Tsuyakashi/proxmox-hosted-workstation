output "ct_id" {
  value = proxmox_virtual_environment_container.this.id
}

output "vm_id" {
  description = "Numeric CTID."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "ipv4" {
  description = "IPv4 addresses Proxmox reports per network interface."
  value       = proxmox_virtual_environment_container.this.ipv4
}

output "passed_devices" {
  value = [for d in proxmox_virtual_environment_container.this.device_passthrough : d.path]
}
