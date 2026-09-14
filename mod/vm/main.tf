# Was a single resource (one mapping, one entry per PCI function) before the
# switch to whole-device / multi-device passthrough.
moved {
  from = proxmox_hardware_mapping_pci.this
  to   = proxmox_hardware_mapping_pci.this["gtx950"]
}

# One cluster-wide hardware mapping per passed-through device. Creating and
# using these needs Mapping.Modify + Mapping.Use on the API token's role —
# no root@pam required (despite the bpg README's "Known Issues" section,
# which is stale for provider >= 0.111.1 / PVE 9.x).
#
# The mappings describe physical devices on the node, not this VM — set
# manage_mappings = false in envs that only *consume* mappings another env
# already owns (mutually-exclusive workstation VMs on the same hardware).
resource "proxmox_hardware_mapping_pci" "this" {
  for_each = var.manage_mappings ? { for d in var.passthrough : d.name => d } : {}

  name = each.value.name

  # Exactly one map entry for this node. Multiple entries are meant as
  # per-node alternatives for a cluster — giving two here (one per PCI
  # function) makes Proxmox forward only the first one.
  map = [
    {
      node         = var.node_name
      path         = each.value.path
      id           = each.value.id
      subsystem_id = each.value.subsystem_id
      iommu_group  = each.value.iommu_group
    }
  ]
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  on_boot   = var.on_boot

  machine = "q35"
  bios    = "ovmf"

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
  }

  agent {
    enabled = var.agent_enabled
  }

  efi_disk {
    datastore_id = var.datastore_id_disk
    file_format  = "raw"
    type         = "4m"
  }

  disk {
    datastore_id = var.datastore_id_disk
    interface    = var.disk_interface
    size         = var.disk_size
    file_format  = "raw"
  }

  # Optional second removable-media disk for a one-time install source (e.g.
  # a macOS recovery/BaseSystem image) that isn't the primary `cdrom` slot --
  # that one is reserved for the OS installer ISO (Windows) or the OpenCore
  # boot loader (macOS, attached every boot, not just install). Nullable /
  # additive: env/windows never sets installer_image_file_id, so this block
  # emits nothing and its plan is unaffected.
  dynamic "disk" {
    for_each = var.installer_image_file_id != null ? [var.installer_image_file_id] : []
    content {
      datastore_id = var.datastore_id_disk
      interface    = var.installer_interface
      import_from  = disk.value
      file_format  = "raw"
    }
  }

  cdrom {
    file_id   = coalesce(var.iso_file_id, "none")
    interface = var.cdrom_interface
  }

  # Try the ISO first, then the installed disk. Must match the interfaces
  # actually assigned — verify with `qm config <vmid> | grep -E '^(ide|sata|boot)'`
  # after apply (the provider can move the cdrom slot).
  boot_order = [var.cdrom_interface, var.disk_interface]

  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac
    model       = var.network_model
  }

  # Whole PCI devices -> hostpci0..N in list order.
  dynamic "hostpci" {
    for_each = { for idx, d in var.passthrough : idx => d }
    content {
      device = "hostpci${hostpci.key}"
      mapping = (var.manage_mappings
        ? proxmox_hardware_mapping_pci.this[hostpci.value.name].name
      : hostpci.value.name)
      pcie     = true
      rombar   = true
      xvga     = hostpci.value.primary_gpu
      rom_file = hostpci.value.rom_file
    }
  }

  dynamic "usb" {
    for_each = var.usb_devices
    content {
      host = usb.value.host
      usb3 = usb.value.usb3
    }
  }

  # With a primary-GPU (x-vga) device the Proxmox web console falls back to
  # this serial redirect — that is how OVMF/boot output is still reachable.
  serial_device {}

  operating_system {
    type = var.os_type
  }

  lifecycle {
    # hook_script_file_id: root@pam-only (`qm set --hookscript` on the node,
    #   see root README "Установка (разово на ноду)") -- this resource never
    #   sets it, so without this the provider's own schema default (null)
    #   fights whatever a node-side `qm set` actually put there and a stray
    #   `terraform apply` would silently rip the arbiter hookscript back off.
    #   Confirmed on real state (env/windows, 2026-09-14): a plain `plan`
    #   against the live windows VM showed exactly this diff before the fix.
    # started: the arbiter / workstation.sh own run state after the first
    #   create, same as mod/ct's own `started` -- the provider's schema
    #   default (true) otherwise drifts against a guest that's meant to be
    #   off, and a stray apply would actually power it on.
    ignore_changes = [hook_script_file_id, started]
  }
}
