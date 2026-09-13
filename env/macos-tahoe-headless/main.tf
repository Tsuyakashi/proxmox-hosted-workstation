# macOS Tahoe headless build backend on pve-rog -- independent of the
# bare-pve GPU-passthrough story (env/windows, env/ubuntu, mod/vm, mod/ct,
# scripts/gpu-arbiter.sh). No GPU, no passthrough, no arbiter, different
# node. Purpose: CLI/SSH access for Xcode CLI builds, occasional
# VNC/Screen Sharing -- not a desktop with a physical-monitor output.
#
# See README.md in this directory for the full install-from-scratch order
# (OpenCore ISO build, recovery-media fetch, first-boot Recovery install)
# and "Известные ограничения" for what's a verified community baseline vs.
# what will likely need on-node iteration.

module "macos_headless" {
  source    = "../../mod/vm-headless"
  name      = var.vm_name
  node_name = var.proxmox_node

  cores   = var.cores
  sockets = var.sockets
  memory  = var.memory
  mac     = var.mac

  network_model = var.network_model

  disk_size = var.disk_size

  opencore_iso_file_id    = var.opencore_iso_file_id
  installer_image_file_id = var.installer_image_file_id

  # Manual start only -- no autostart race, no lifecycle script needed since
  # this guest never shares hardware with another guest.
  on_boot = false
}
