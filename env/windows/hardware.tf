# Cluster PCI mappings for the whole-workstation passthrough on bare-pve.
# Only storage (SATA, IOMMU group 9 — the PVE boot disk) and the Realtek NIC
# (vmbr0) stay with the host.
#
# One map entry per mapping = this node only. A second entry would be a
# per-node alternative, not a second function.
#
# ids / subsystem ids / groups verified on bare-pve (2026-11-16):
#   lspci -nn; readlink -f /sys/bus/pci/devices/0000:<addr>/iommu_group
#   cat /sys/bus/pci/devices/0000:<addr>/subsystem_{vendor,device}
locals {
  pci = {
    # Function-less path -> all four functions of the card go together:
    # 01:00.0 VGA, .1 HDMI audio, .2 USB-C xHCI, .3 UCSI. Group 1.
    "gtx1660s" = { path = "0000:01:00", id = "10de:21c4", subsystem_id = "1458:4014", iommu_group = 1 }
    # Intel 8-series USB + onboard audio (line-out / mic jacks).
    "usb-xhci"      = { path = "0000:00:14.0", id = "8086:8c31", subsystem_id = "1849:8c31", iommu_group = 2 }
    "usb-ehci1"     = { path = "0000:00:1d.0", id = "8086:8c26", subsystem_id = "1849:8c26", iommu_group = 8 }
    "usb-ehci2"     = { path = "0000:00:1a.0", id = "8086:8c2d", subsystem_id = "1849:8c2d", iommu_group = 4 }
    "onboard-audio" = { path = "0000:00:1b.0", id = "8086:8c20", subsystem_id = "1849:7662", iommu_group = 5 }
  }
}

resource "proxmox_hardware_mapping_pci" "this" {
  for_each = local.pci

  name = each.key
  map = [{
    node         = var.proxmox_node
    path         = each.value.path
    id           = each.value.id
    subsystem_id = each.value.subsystem_id
    iommu_group  = each.value.iommu_group
  }]
}
