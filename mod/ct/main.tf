# Generic Proxmox LXC container module.
#
# Counterpart of mod/vm. mod/vm hands whole PCI functions to a guest via
# vfio-pci hardware mappings; a container instead runs on the host kernel and
# gets individual host device nodes. Those nodes (`dev[n]:`), the hookscript,
# and every feature flag except `nesting` are hard-coded root@pam in Proxmox,
# so this module only does what an API token can — the rest is applied on the
# node by scripts/lxc-ct-passthrough.sh.
#
# The two approaches to the same GPU are MUTUALLY EXCLUSIVE at the host level:
# vfio-pci binding (mod/vm) vs. the host NVIDIA driver (this module). The flip
# is a live PCI rebind by scripts/gpu-arbiter.sh — no reboot.

resource "proxmox_virtual_environment_container" "this" {
  node_name     = var.node_name
  vm_id         = var.vm_id
  unprivileged  = var.unprivileged
  start_on_boot = var.start_on_boot
  started       = var.started
  tags          = var.tags

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

  # Proxmox only lets a non-root@pam token touch `nesting` (and only on an
  # unprivileged CT — see check_ct_modify_config_perm in pve-container). Every
  # other feature flag — keyctl, fuse, mount — raises a 403 for the token
  # ("changing feature flags (except nesting) is only allowed for root@pam").
  # Those are applied on the node by scripts/lxc-ct-passthrough.sh, together
  # with the dev[n] / hookscript bits that are also hard-coded root@pam only.
  features {
    nesting = var.nesting
  }

  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [var.startup_order]
    content {
      order = startup.value
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
    # template: only read at create time — a newer tarball at the same volume id
    #   must not destroy/recreate a live workstation.
    # started: the arbiter / workstation.sh own run state after the first create;
    #   Terraform must not stop or start the CT on later applies.
    ignore_changes = [operating_system[0].template_file_id, started]
  }
}
