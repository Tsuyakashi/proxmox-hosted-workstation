module "minimal_vm" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  cores          = var.cores
  memory         = var.memory
  mac            = var.mac
  os_type        = var.os_type
  agent_enabled  = var.agent_enabled
  iso_file_id    = var.iso_file_id
  disk_interface = "sata0"
  disk_size      = 60

  on_boot = false

  # amd-pve: AMD A4-5300 + FCH (Family 15h). Groups verified with:
  #   for d in /sys/kernel/iommu_groups/*/devices/*; do ... done
  #
  #   group 0: 00:02.0 root port + 01:00.0 GTX 950 + 01:00.1 HDMI audio
  #   group 3: 00:12.0 OHCI + 00:12.2 EHCI  <- Bus 001/003: keyboard, mouse, PCM2902
  #   group 4: 00:13.0 OHCI + 00:13.2 EHCI  (unused ports, stays with host)
  #   group 5: SMBus + IDE + Azalia + LPC   -> NOT passable, onboard audio dropped
  #   group 7: 00:14.5 OHCI                 (stays with host)
  #
  # Host keeps SATA (group 2) and the Realtek NIC (group 1, vmbr0) + USB on 13.x/14.5.
  #
  # Mapping names are cluster-wide and env/windows (bare-pve) already owns
  # gtx950/usb-*/onboard-audio — hence the amd- prefix.
  passthrough = [
    {
      name         = "amd-gtx950"
      path         = "0000:01:00" # function-less -> 01:00.0 (VGA) + 01:00.1 (audio)
      id           = "10de:1402"
      subsystem_id = "10de:1402"
      iommu_group  = 0
      # GTX 950 has no UEFI GOP: keep false for install (std VGA + noVNC),
      # flip true once Windows + the NVIDIA driver are in.
      primary_gpu = var.gpu_primary
    },
    {
      name         = "amd-usb12"
      path         = "0000:00:12" # function-less -> 00:12.0 (OHCI) + 00:12.2 (EHCI companion pair)
      id           = "1022:7807"
      iommu_group  = 3
      subsystem_id = "1849:7807"
    },
  ]
}
