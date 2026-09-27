# macOS Tahoe + OpenCore Legacy Patcher (OCLP) root-patch experimental track
# on bare-pve -- SEPARATE from env/macos-tahoe-desktop (VM 103, "stable"
# High Sierra + NVIDIA Web Driver track, see that env's README for the full
# saga and the driver-level hang it's currently blocked on).
#
# Per docs/hackintosh-nvidia.md (research doc, repo root): OCLP ships an
# officially documented post-install root-patch path that restores
# accelerated (non-Metal, on Big Sur+) graphics for GPUs Apple dropped
# driver support for -- Nvidia Kepler is solidly documented/confirmed in
# OCLP's own changelogs; Maxwell (our GM206/GTX950) is listed alongside it
# but less battle-tested for recent macOS (Sonoma/Sequoia/Tahoe) specifically.
# This env exists to actually test that, on Tahoe, per user's explicit ask.
#
# Same physical hardware, same vfio-pci ACPI-hotplug root-cause fix (see
# env/macos-tahoe-desktop/README.md's "ПРОРЫВ" section -- ioreg now shows a
# real promoted IOPCIDevice, not a bare ACPI placeholder, independent of
# macOS version) -- consumes the SAME cluster hardware_mapping_pci entries
# env/windows owns (manage_mappings = false), same as every other guest here.
#
# Deliberately a DIFFERENT vm_name than "macos-workstation" so
# scripts/gpu-arbiter.sh's automatic pre-start hook leaves this guest alone
# (see variables.tf's vm_name docstring) -- GPU/USB/audio still gets bound
# via the same arbiter, just manually: `scripts/gpu-arbiter.sh switch macos`
# before `qm start <this vmid>`.
#
# No kvm_arguments here on purpose, same reasoning as macos-tahoe-desktop --
# the ACPI-hotplug `-global ICH9-LPC...` arg is root@pam-only (`args:` in
# qm.conf), applied directly via `qm set` on the node, never through
# Terraform (conflicts with the API token) -- must be removed before any
# `terraform apply` and re-added after, same discipline as VM 103.

module "macos_tahoe_oclp" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  cores  = var.cores
  memory = var.memory
  mac    = var.mac

  network_model = "vmxnet3" # Same fix as env/macos-tahoe-desktop -- vmxnet3
  # is Apple's own officially-supported VMware-guest driver, built into every
  # macOS including the trimmed Recovery kernel collection, no OpenCore kext
  # injection needed. e1000/e1000e left Recovery's `ifconfig -a` empty.

  os_type       = "l26" # no macOS ostype in Proxmox; "Linux" is LongQT-sea's explicit pick

  disk_interface = "sata0"
  disk_size      = var.disk_size

  cdrom_interface = "ide0" # OpenCore boot ISO -- every boot, not just install
  iso_file_id     = var.opencore_iso_file_id

  installer_interface     = "sata1"
  installer_image_file_id = var.installer_image_file_id

  # Manual start only -- see the vm_name docstring on why this guest isn't
  # wired into the arbiter's automatic pre-start hook.
  on_boot = false

  manage_mappings = false
  passthrough = [
    {
      name        = "gtx950"
      primary_gpu = var.gpu_primary
      rom_file    = var.gpu_rom_file
    },
    { name = "usb-xhci" },
    { name = "usb-ehci1" },
    { name = "usb-ehci2" },
    { name = "onboard-audio" },
  ]
}
