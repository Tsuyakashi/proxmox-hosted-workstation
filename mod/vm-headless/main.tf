# Headless macOS VM -- OpenCore/hackintosh, no GPU passthrough, no
# gpu-arbiter involvement. Independent of mod/vm: no hardware_mapping_pci
# resource, no hostpci block, nothing here contends for bare-pve's GPU or
# participates in scripts/gpu-arbiter.sh at all.

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  on_boot   = var.on_boot

  machine = "q35"
  bios    = "ovmf"

  cpu {
    cores   = var.cores
    sockets = var.sockets
    type    = var.cpu_type
  }

  memory {
    dedicated = var.memory
    # No `floating` -> no balloon target -> no virtio-balloon device driven.
    # Apple ships no balloon driver for macOS; this reservation is hard RAM.
  }

  agent {
    enabled = var.agent_enabled
  }

  efi_disk {
    datastore_id      = var.datastore_id_disk
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = var.efi_pre_enrolled_keys
  }

  # Persistent macOS data disk.
  disk {
    datastore_id = var.datastore_id_disk
    interface    = var.disk_interface
    size         = var.disk_size
    file_format  = "raw"
  }

  # Optional recovery/BaseSystem install media -- imported once at create
  # time (not a live mount). Unset installer_image_file_id and re-apply to
  # detach it once macOS is actually installed on the disk above.
  dynamic "disk" {
    for_each = var.installer_image_file_id != null ? [var.installer_image_file_id] : []
    content {
      datastore_id = var.datastore_id_disk
      interface    = var.installer_interface
      import_from  = disk.value
      file_format  = "raw"
    }
  }

  # OpenCore boot ISO -- the actual bootloader, attached every boot, not just
  # for install. See env README for how to build/upload it.
  cdrom {
    file_id   = var.opencore_iso_file_id
    interface = var.cdrom_interface
  }

  boot_order = [var.cdrom_interface, var.disk_interface]

  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac
    model       = var.network_model
  }

  # Software framebuffer only -- no Metal/GPU acceleration. Access is via
  # VNC/Screen Sharing over this, or SSH once the network is up.
  vga {
    type = var.vga_type
  }

  # Proxmox's OWN tablet emulation defaults to true regardless of whether
  # this resource sets anything -- simply omitting the attribute does NOT
  # mean "no tablet" (confirmed empirically: a fresh VM came up with
  # `tablet: 1` with no tablet_device line in this resource at all). Must
  # be explicit false: kvm_arguments' `-device virtio-tablet` is the one
  # and only pointer device, per LongQT-sea's documented macOS-26 cursor-
  # freeze fix (their "better fix" starts with disabling Proxmox's native
  # tablet before adding virtio-tablet -- having both back is exactly the
  # bug that fix exists to avoid).
  tablet_device = false

  # kvm_arguments (-> Proxmox's `args:` config key) is NOT set here. Proxmox
  # hard-restricts `args:` to root@pam regardless of API token privileges --
  # same class of restriction this repo already documents for LXC's
  # `dev[n]`/`hookscript` (see root README "root@pam-ограничения LXC").
  # Confirmed empirically: `terraform apply` with this set fails with
  # "only root can set 'args' config" (HTTP 500), token or not. Apply
  # var.kvm_arguments by hand on the node instead -- see the `kvm_arguments`
  # output and the env README's install steps.

  operating_system {
    type = var.os_type
  }

  lifecycle {
    # Without this, `plan` sees the root@pam-applied `args:` value that
    # `refresh` read back from the API, compares it against this resource's
    # silence on kvm_arguments, and wants to null it out -- which either
    # fails the same "only root can set 'args' config" way, or (worse)
    # actually clears the one-time manual step. Same idiom mod/ct already
    # uses for hook_script_file_id -- a node-managed field Terraform must
    # not fight over.
    ignore_changes = [kvm_arguments]
  }
}
