#!/bin/bash
set -euo pipefail

# ============================================================
# Post-install setup for the Ubuntu workstation VM: proprietary NVIDIA driver
# + Steam / Discord / VS Code. Run INSIDE the VM as root (or with sudo).
# Re-runnable.
# ============================================================
#
#   # from the desk, in a terminal in the freshly-installed Ubuntu:
#   curl -fsSL <this-file> | sudo bash
#   # or: scp it in and `sudo bash ubuntu-guest-provision.sh`
#
# This is a real VM with its own Ubuntu kernel, so the NVIDIA driver installs
# the normal way (DKMS kernel module included) — none of the host-kernel
# gymnastics the LXC approach needed.
#
# Toggle: INSTALL_STEAM / INSTALL_DISCORD / INSTALL_VSCODE (default 1),
#         NVIDIA_METHOD = ubuntu-drivers | run   (default ubuntu-drivers)
#         NVIDIA_RUN_VERSION (only for NVIDIA_METHOD=run; GTX 950 = Maxwell ->
#         the 580 branch is the last supported, e.g. 580.178.04)

INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_DISCORD="${INSTALL_DISCORD:-1}"
INSTALL_VSCODE="${INSTALL_VSCODE:-1}"
NVIDIA_METHOD="${NVIDIA_METHOD:-ubuntu-drivers}"
NVIDIA_RUN_VERSION="${NVIDIA_RUN_VERSION:-580.178.04}"

export DEBIAN_FRONTEND=noninteractive
log() { echo "[provision] $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

# ------------------------------------------------------------
# 1. Base — updates, 32-bit, build tools, media stack
# ------------------------------------------------------------
log "apt update + base packages"
dpkg --add-architecture i386
add-apt-repository -y multiverse || true
apt-get update
apt-get -y full-upgrade
apt-get install -y \
  build-essential dkms linux-headers-generic \
  curl wget ca-certificates gnupg pciutils \
  mesa-utils mesa-vulkan-drivers mesa-vulkan-drivers:i386 vulkan-tools \
  qemu-guest-agent

# ------------------------------------------------------------
# 2. Proprietary NVIDIA driver (kernel module + DKMS — this is a VM)
# ------------------------------------------------------------
if nvidia-smi >/dev/null 2>&1; then
  log "nvidia driver already loaded ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader))"
elif [ "$NVIDIA_METHOD" = run ]; then
  log "nvidia driver via .run $NVIDIA_RUN_VERSION"
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_RUN_VERSION}.run"
  [ -f "$RUN" ] || curl -fL --progress-bar -o "$RUN" \
    "https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_RUN_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_RUN_VERSION}.run"
  sh "$RUN" --silent --dkms --install-libglvnd --install-compat32-libs --no-questions --ui=none
else
  log "nvidia driver via ubuntu-drivers"
  apt-get install -y ubuntu-drivers-common
  # GTX 950 (Maxwell) — pick the newest branch ubuntu-drivers offers that
  # still lists the card; usually nvidia-driver-5xx. autoinstall picks it.
  ubuntu-drivers install || apt-get install -y nvidia-driver-580 || apt-get install -y nvidia-driver-570
fi

# ------------------------------------------------------------
# 3. Steam
# ------------------------------------------------------------
if [ "$INSTALL_STEAM" = 1 ]; then
  log "steam (+ i386)"
  echo "steam steam/question select 'I AGREE'" | debconf-set-selections
  echo "steam steam/license note ''" | debconf-set-selections
  apt-get install -y steam-installer || {
    curl -fL -o /root/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb
    apt-get install -y /root/steam.deb
  }
fi

# ------------------------------------------------------------
# 4. Discord
# ------------------------------------------------------------
if [ "$INSTALL_DISCORD" = 1 ]; then
  log "discord"
  curl -fL -o /root/discord.deb "https://discord.com/api/download?platform=linux&format=deb"
  apt-get install -y /root/discord.deb
fi

# ------------------------------------------------------------
# 5. VS Code (Microsoft apt repo)
# ------------------------------------------------------------
if [ "$INSTALL_VSCODE" = 1 ]; then
  log "vscode"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    >/etc/apt/sources.list.d/vscode.list
  apt-get update
  apt-get install -y code
fi

systemctl enable --now qemu-guest-agent 2>/dev/null || true

echo ""
echo "=== checks ==="
nvidia-smi || echo "!! nvidia-smi failed — reboot the VM, then check 'lsmod | grep nvidia'"
echo ""
echo "Reboot the VM. After the NVIDIA driver is in, on the Proxmox node set"
echo "gpu_primary=true is already the default — the monitor is driven by the card."
echo "Enable the guest agent in Terraform: -var agent_enabled=true, then apply."
