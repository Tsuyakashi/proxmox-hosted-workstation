# Ubuntu desktop workstation on bare-pve — an LXC container, not a VM.
#
# Why a container:
#   - No vfio, no OVMF, no Code 43, no "monitor dark until the driver loads".
#     The CT shares the host's NVIDIA kernel driver; only the userspace driver
#     (same version, --no-kernel-module) goes inside.
#   - The GPU is handed in as plain device nodes (/dev/nvidia*, /dev/dri/*),
#     so `terraform apply` no longer fights the host over PCI ownership.
#
# HARD REQUIREMENT — host must run the NVIDIA driver, NOT vfio-pci:
#   This is the exact opposite of scripts/iommu-vfio-setup.sh. The GPU on
#   bare-pve can be bound to vfio-pci (for env/windows) OR to nvidia (for this
#   CT), never both. env/windows and env/ubuntu are mutually exclusive and
#   NEITHER autostarts. The gpu-arbiter.sh hookscript (pre-start) rebinds the
#   GPU/USB on `pct start` and aborts the start if the Windows VM is running;
#   scripts/workstation.sh is the CLI on top. See README "Переключение ОС".
#
# PRIVILEGED container (var.unprivileged = false). A full Ubuntu GNOME / GDM
# desktop needs systemd-logind to hand out a real graphical session + seat and
# a working udev — an unprivileged Proxmox CT gives neither. See mod/ct's
# `unprivileged` variable for the trade-off.
#
# The .tar.zst template is a standard minimal Ubuntu rootfs (NOT a cloud
# image); the full `ubuntu-desktop` stack + GDM + the NVIDIA userspace driver
# are installed on first boot by scripts/lxc-ubuntu-desktop-provision.sh (run
# inside the CT).
#
# FEATURES + DEVICE PASSTHROUGH + HOOKSCRIPT ARE NOT SET HERE. On a privileged
# CT an API token may not send a `features {}` block at all, and Proxmox
# hard-codes `dev[n]:` and `hookscript:` to root@pam regardless. All of it is
# applied out of band as root on the node:
#
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid>
#
# which sets `--features nesting=1,keyctl=1,fuse=1`, writes raw `lxc.*` GPU/DRI
# (+ USB/input/snd + apparmor) lines and runs
# `pct set <ctid> --hookscript local:snippets/gpu-arbiter.sh`. Re-run after any
# `terraform apply` that recreates the CT.

module "ubuntu_ct" {
  source    = "../../mod/ct"
  name      = var.ct_name
  node_name = var.proxmox_node

  cores            = var.cores
  memory           = var.memory
  swap             = var.swap
  unprivileged     = var.unprivileged
  template_file_id = var.template_file_id
  os_type          = "ubuntu"
  disk_size        = var.disk_size
  mac              = var.mac
  ipv4_address     = var.ipv4_address
  ipv4_gateway     = var.ipv4_gateway
  # bare-pve's own resolv.conf points at Tailscale MagicDNS (100.100.100.100),
  # which a non-Tailscale CT can't reach -> apt/steam/etc. fail on DNS. Give
  # the CT real resolvers instead of inheriting the node's.
  nameservers = var.nameservers

  ssh_public_keys = var.ssh_public_keys

  # Lifecycle is external (gpu-arbiter.sh pre-start hook + workstation.sh CLI).
  start_on_boot = false

  tags = ["workstation", "gpu", "ubuntu"]

  # No features{} block reaches Proxmox for a privileged CT (see mod/ct).
  # nesting + keyctl + fuse + the GPU/USB dev lines + the hookscript + the
  # apparmor profile are all added on the node by
  # scripts/lxc-ct-passthrough.sh.
}
