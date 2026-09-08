# Ubuntu 26.04 desktop workstation on bare-pve — a VM with full passthrough,
# exactly like env/windows. Goal: sit at the desk, picture on the monitors,
# keyboard/mouse/USB passed through, play Steam games. NOT remote.
#
# Booting: OVMF has no GOP for the GTX 950 (no UEFI vBIOS), so the physical
# monitor stays dark through OVMF/GRUB. The in-tree nouveau driver lights it
# up the moment KMS initialises — no Code 43 games, unlike Windows — so the
# installer IS visible on the monitor. Install the proprietary NVIDIA driver
# inside the VM afterwards (scripts/ubuntu-guest-provision.sh); DKMS builds
# against the VM's own Ubuntu kernel, none of the host-kernel weirdness.
#
# env/windows owns the cluster PCI mappings (manage_mappings = true there);
# this env only consumes them by name. The two are MUTUALLY EXCLUSIVE — same
# GPU + USB controllers — and NEITHER autostarts. scripts/gpu-arbiter.sh (a
# Proxmox pre-start hook) refuses to start one while the other runs;
# scripts/workstation.sh is the CLI. Both guests want vfio-pci, so there is
# no driver swap — just the "one at a time" lock.

module "ubuntu_vm" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  cores           = var.cores
  memory          = var.memory
  mac             = var.mac
  os_type         = var.os_type
  agent_enabled   = var.agent_enabled
  iso_file_id     = var.iso_file_id
  disk_interface  = "scsi0"
  disk_size       = 64
  network_model   = "virtio"
  on_boot         = false
  manage_mappings = false # env/windows creates the mappings; we attach by name

  passthrough = [
    {
      name        = "gtx950"
      primary_gpu = var.gpu_primary
    },
    { name = "usb-xhci" },
    { name = "usb-ehci1" },
    { name = "usb-ehci2" },
    { name = "onboard-audio" },
  ]
}
