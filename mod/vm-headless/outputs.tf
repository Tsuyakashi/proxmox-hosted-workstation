output "vm_id" {
  value = proxmox_virtual_environment_vm.this.id
}

output "kvm_arguments" {
  description = <<-EOT
    Not applied by Terraform -- Proxmox restricts the `args:` VM config key
    to root@pam regardless of API token privileges. Apply once by hand:
      ssh <node> "qm set <vm_id> --args '<this value>'"
  EOT
  value       = var.kvm_arguments
}
