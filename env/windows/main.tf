# Windows workstation on bare-pve: whole-workstation passthrough VM.
#
# Lifecycle is external: gpu-arbiter.sh (pre-start hook) + workstation.sh.
# The hookscript itself is root@pam-only:
#   ssh bare-pve 'qm set <vmid> --hookscript local:snippets/gpu-arbiter.sh'
#
# Shared game disks: sata1 (SSD) and sata2 (HDD) are this VM's disks, but the
# arbiter mounts them on the host for the Ubuntu CT whenever Windows is off.
# NTFS, labels games-ssd / games-hdd (the arbiter finds them by label).
module "vm" {
  source = "git::https://github.com/Tsuyakashi/iac-proxmox-lab.git//modules/pve-vm?ref=modules/v0.2.0"

  node_name = var.proxmox_node
  name      = "windows-workstation" # gpu-arbiter matches the guest by this name
  tags      = ["workstation", "gpu", "windows"]
  os_type   = "win10"

  # workstation.sh owns start/stop: no autostart race with the Ubuntu CT.
  on_boot = false
  started = false

  # The shared game disks live here: no accidental destroy of the VM.
  protection = var.protection

  cpu         = { cores = var.cores, type = "host" }
  memory      = var.memory
  secure_boot = false

  # SATA everywhere: Windows sees it without the virtio-win drivers.
  disk = {
    interface   = "sata0"
    size        = 60
    file_format = "raw"
  }
  extra_disks = [
    { interface = "sata1", datastore_id = "local-lvm", size = var.games_ssd_size, file_format = "raw", ssd = true, backup = false },
    { interface = "sata2", datastore_id = "hdd", size = var.games_hdd_size, file_format = "raw", backup = false },
  ]

  cdrom = var.iso_file_id == null ? null : { file_id = var.iso_file_id, interface = "ide2" }

  networks = [{
    bridge      = "vmbr0"
    mac_address = "BC:24:11:F9:5D:82"
    model       = "e1000" # the installer has no virtio NIC driver
    firewall    = false
  }]

  agent = { enabled = var.agent_enabled }

  # gpu_primary = false only for a from-scratch install: OVMF has no GOP for
  # the card, so the installer needs the emulated VGA + noVNC until the NVIDIA
  # driver is in.
  vga_type = var.gpu_primary ? null : "std"

  hostpci = [
    { mapping = proxmox_hardware_mapping_pci.this["gtx1660s"].name, xvga = var.gpu_primary },
    { mapping = proxmox_hardware_mapping_pci.this["usb-xhci"].name },
    { mapping = proxmox_hardware_mapping_pci.this["usb-ehci1"].name },
    { mapping = proxmox_hardware_mapping_pci.this["usb-ehci2"].name },
    { mapping = proxmox_hardware_mapping_pci.this["onboard-audio"].name },
  ]
}
