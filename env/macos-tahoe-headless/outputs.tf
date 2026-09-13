output "vm_id" {
  value = module.macos_headless.vm_id
}

output "kvm_arguments" {
  description = "Not applied by Terraform -- see mod/vm-headless's own output of the same name."
  value       = module.macos_headless.kvm_arguments
}
