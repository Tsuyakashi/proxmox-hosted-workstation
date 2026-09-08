# Generic Proxmox LXC container module.
#
# Counterpart of mod/vm. Where mod/vm hands whole PCI functions to a guest via
# vfio-pci hardware mappings, this module shares individual host device nodes
# (`device_passthrough` -> Proxmox `dev[n]:`) into a container that runs on the
# host kernel. The two approaches to the same GPU are MUTUALLY EXCLUSIVE at the
# host level: vfio-pci binding (mod/vm) vs. the host NVIDIA driver being loaded
# (this module). Switching is a host reconfigure + reboot, not just a
# `terraform apply` — see scripts/lxc-nvidia-host-setup.sh.

resource "proxmox_virtual_environment_container" "this" {
  node_name     = var.node_name
  vm_id         = var.vm_id
  unprivileged  = var.unprivileged
  start_on_boot = var.start_on_boot
  tags          = var.tags

  hook_script_file_id = var.hook_script_file_id

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.datastore_id_rootfs
    size         = var.disk_size
  }

  network_interface {
    name        = "eth0"
    bridge      = var.network_bridge
    mac_address = var.mac
  }

  initialization {
    hostname = var.name

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_address == "dhcp" ? null : var.ipv4_gateway
      }
    }

    dynamic "dns" {
      for_each = var.nameservers == null && var.search_domain == null ? [] : [1]
      content {
        domain  = var.search_domain
        servers = var.nameservers
      }
    }

    dynamic "user_account" {
      for_each = length(var.ssh_public_keys) > 0 || var.password != null ? [1] : []
      content {
        keys     = var.ssh_public_keys
        password = var.password
      }
    }
  }

  features {
    nesting = var.nesting
    keyctl  = var.keyctl
    fuse    = var.fuse
    mount   = var.mount_feature
  }

  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [var.startup_order]
    content {
      order = startup.value
    }
  }

  dynamic "device_passthrough" {
    for_each = { for d in var.device_passthrough : d.path => d }
    content {
      path       = device_passthrough.value.path
      mode       = device_passthrough.value.mode
      deny_write = device_passthrough.value.deny_write
      uid        = device_passthrough.value.uid
      gid        = device_passthrough.value.gid
    }
  }

  dynamic "mount_point" {
    for_each = { for m in var.mount_points : m.path => m }
    content {
      volume        = mount_point.value.volume
      path          = mount_point.value.path
      size          = mount_point.value.size
      read_only     = mount_point.value.read_only
      acl           = mount_point.value.acl
      backup        = mount_point.value.backup
      mount_options = mount_point.value.mount_options
    }
  }

  lifecycle {
    # The template tarball is only read at create time; a newer template in the
    # same volume id must not trigger a destroy/recreate of a live workstation.
    ignore_changes = [operating_system[0].template_file_id]
  }
}
