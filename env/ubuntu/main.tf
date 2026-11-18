# Ubuntu desktop workstation on bare-pve: a PRIVILEGED LXC, not a VM.
#
# It shares the host's NVIDIA kernel driver (userspace driver inside, same
# version, --no-kernel-module) and gets the GPU/USB/input/snd as device nodes.
# Anti-cheats ban hypervisors by CPUID; an LXC is not one. Privileged because
# GDM needs a real logind seat + working udev.
#
# Everything root@pam-only is done on the node, not here:
#   ssh bare-pve /root/lxc-ct-passthrough.sh <ctid>
# features (nesting, keyctl, fuse), raw lxc.* device lines, apparmor, the
# hookscript and the bind mounts of the shared game disks. Re-run it after any
# apply that recreates the CT.
#
# Shared game disks (/mnt/games-ssd, /mnt/games-hdd) are the Windows VM's
# sata1/sata2; gpu-arbiter mounts them on the host before this CT starts and
# unmounts after it stops.
module "ct" {
  source = "git::https://github.com/Tsuyakashi/iac-proxmox-lab.git//modules/pve-ct?ref=modules/v0.2.0"

  node_name        = var.proxmox_node
  name             = "ubuntu-workstation" # gpu-arbiter matches the CT by this hostname
  tags             = ["workstation", "gpu", "ubuntu"]
  unprivileged     = false
  template_file_id = var.template_file_id

  # Lifecycle is external (gpu-arbiter pre-start + workstation.sh). Created
  # stopped: lxc-ct-passthrough.sh must run before the first start.
  start_on_boot = false
  started       = false

  cores  = var.cores
  memory = var.memory
  swap   = 0
  disk   = { size = var.disk_size }

  network = {
    mac_address = "BC:24:11:AB:CD:01"
    firewall    = false
  }
  # Never the node's resolv.conf (MagicDNS, unreachable from the CT).
  nameservers = ["192.168.100.1", "1.1.1.1"]

  ssh_public_keys = var.ssh_public_keys
}
