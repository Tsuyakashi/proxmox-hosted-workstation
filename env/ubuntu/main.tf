# Ubuntu desktop workstation on bare-pve — now an LXC container, not a VM.
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
#   CT), never both. Flip the host with scripts/lxc-nvidia-host-setup.sh and
#   reboot before this env can start. env/windows and env/ubuntu stay mutually
#   exclusive — the conflict just moved from the mapping layer to the host
#   driver layer.
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

  tags = ["workstation", "gpu", "ubuntu"]

  # nesting/keyctl/fuse default true in the module — a GNOME session, gdm and
  # Flatpak all need them.

  # NVIDIA GPU + render nodes. Paths must exist on the host (nvidia driver
  # loaded, nvidia-persistenced or the udev rules from lxc-nvidia-host-setup.sh
  # creating the uvm nodes). Mode 0666 so the unprivileged CT can open them.
  device_passthrough = [
    { path = "/dev/nvidia0" },
    { path = "/dev/nvidiactl" },
    { path = "/dev/nvidia-uvm" },
    { path = "/dev/nvidia-uvm-tools" },
    { path = "/dev/nvidia-modeset" },
    { path = "/dev/dri/card0" },
    { path = "/dev/dri/renderD128" },

    # Local keyboard/mouse for a CT that drives the physical monitor. A whole
    # USB *controller* is PCI (VM-only); a container gets the evdev nodes
    # instead. Uncomment once the architecture (physical seat vs. headless +
    # RDP/Sunshine) is settled — see README.
    # { path = "/dev/input/event0" },
    # { path = "/dev/input/mice" },
    # { path = "/dev/tty7" },
  ]
}
