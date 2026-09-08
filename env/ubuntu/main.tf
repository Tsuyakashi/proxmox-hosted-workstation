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
# The .tar.zst template is a standard minimal Ubuntu rootfs (NOT a cloud
# image); ubuntu-desktop + the NVIDIA userspace driver are installed on first
# boot by scripts/lxc-ubuntu-desktop-provision.sh (run inside the CT).

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

  ssh_public_keys = var.ssh_public_keys

  # Lifecycle is external — never autostart. gpu-arbiter.sh (installed on the
  # node by scripts/install-gpu-arbiter.sh) runs as this CT's pre-start hook:
  # it rebinds the GPU to nvidia and refuses the start if the Windows VM is up.
  start_on_boot       = false
  hook_script_file_id = var.hook_script_file_id

  tags = ["workstation", "gpu", "ubuntu"]

  # nesting/keyctl/fuse default true in the module — a GNOME session, gdm and
  # Flatpak all need them.

  # --- GPU: stable device nodes, managed by Terraform ------------------------
  # Paths must exist on the host (nvidia driver loaded + nvidia-persistenced /
  # the udev rule from lxc-nvidia-host-setup.sh creating the uvm nodes). Mode
  # 0666 so the unprivileged CT can open them.
  device_passthrough = [
    { path = "/dev/nvidia0" },
    { path = "/dev/nvidiactl" },
    { path = "/dev/nvidia-uvm" },
    { path = "/dev/nvidia-uvm-tools" },
    { path = "/dev/nvidia-modeset" },
    { path = "/dev/dri/card0" },
    { path = "/dev/dri/renderD128" },
  ]

  # --- ALL USB + input + sound: raw lxc.* config ----------------------------
  # A whole USB *controller* is a PCI device (VM-only). A container instead
  # gets the whole USB devfs + evdev + ALSA, which is functionally identical
  # for a workstation (every keyboard/mouse/headset/stick, hotplug included).
  # Terraform's device_passthrough is per-node and cannot express the /dev
  # directory bind-mounts + cgroup major ranges this needs, so it is applied
  # out-of-band and idempotently:
  #
  #   ssh bare-pve scripts/lxc-usb-passthrough.sh <ctid>
  #
  # (re-run after any `terraform apply` that recreates the CT). The script
  # appends c 189:* / c 13:* / c 116:* cgroup allows and bind-mounts
  # /dev/bus/usb, /dev/input, /dev/snd into /etc/pve/lxc/<ctid>.conf.
}
