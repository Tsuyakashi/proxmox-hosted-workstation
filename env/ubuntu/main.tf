# Ubuntu 26.04 desktop workstation on bare-pve.
#
# Same physical devices as env/windows — the two are MUTUALLY EXCLUSIVE:
# only one may be applied/running at a time. env/windows owns the cluster PCI
# mappings; this env only references them by name (manage_mappings = false),
# so env/windows must stay applied (its VM 104 may be stopped).
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

  manage_mappings = false

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
    { name = "gtx950", primary_gpu = true },
    { name = "usb-xhci" },
    { name = "usb-ehci1" },
    { name = "usb-ehci2" },
    { name = "onboard-audio" },
  ]
}
