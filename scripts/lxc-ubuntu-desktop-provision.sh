#!/bin/bash
set -euo pipefail

# ============================================================
# Turn the fresh Ubuntu LXC into a GPU-accelerated desktop.
# Run INSIDE the container. Idempotent-ish (apt is, the .run isn't a no-op
# but re-running it is safe).
# ============================================================
#
#   pct push <ctid> scripts/lxc-ubuntu-desktop-provision.sh /root/provision.sh
#   pct exec <ctid> -- env NVIDIA_VERSION=580.xx.xx bash /root/provision.sh
#
# NVIDIA_VERSION MUST equal the host's `cat /sys/module/nvidia/version`.
# The container installs the USERSPACE half only (--no-kernel-module).

NVIDIA_VERSION="${NVIDIA_VERSION:-}"
DESKTOP="${DESKTOP:-ubuntu-desktop-minimal}"   # or ubuntu-desktop for the full set
ENABLE_XRDP="${ENABLE_XRDP:-1}"                # headless access; set 0 for physical-seat only
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

[ -n "$NVIDIA_VERSION" ] || { echo "set NVIDIA_VERSION to match the host driver" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# 1. Base desktop (from the standard archive — NOT a cloud image)
# ------------------------------------------------------------
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  "$DESKTOP" \
  dbus-user-session systemd-container \
  mesa-utils vulkan-tools \
  curl ca-certificates kmod pciutils

# gdm3 tries to start on a VT; harmless in a CT with nesting. For a headless /
# RDP-only box, switch to multi-user and let xrdp spawn sessions.
if [ "$ENABLE_XRDP" = "1" ]; then
  apt-get install -y --no-install-recommends xrdp xorgxrdp
  adduser xrdp ssl-cert || true
  systemctl enable xrdp
  systemctl set-default graphical.target
fi

# ------------------------------------------------------------
# 2. NVIDIA userspace driver — kernel module comes from the HOST
# ------------------------------------------------------------
CUR="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
if [ "$CUR" = "$NVIDIA_VERSION" ]; then
  echo "[nvidia] userspace $NVIDIA_VERSION already present"
else
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  [ -f "$RUN" ] || curl -fL -o "$RUN" "${RUN_URL_BASE}/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  sh "$RUN" --silent \
    --no-kernel-module \
    --no-kernel-module-source \
    --no-drm \
    --install-libglvnd \
    --no-questions --ui=none
fi

# ------------------------------------------------------------
# 3. Sanity
# ------------------------------------------------------------
echo ""
echo "=== checks ==="
ls -l /dev/nvidia* /dev/dri 2>&1 || echo "!! GPU nodes missing — check env/ubuntu device_passthrough + host driver"
nvidia-smi || echo "!! nvidia-smi failed — version mismatch with host, or nodes not passed"
echo ""
echo "glxinfo (needs an X/EGL context; expect 'NVIDIA' as the renderer once a session runs):"
command -v glxinfo >/dev/null && (glxinfo -B 2>/dev/null | grep -Ei 'vendor|renderer|OpenGL' || true)

echo ""
echo "Done. Reboot the CT (pct reboot <ctid>)."
if [ "$ENABLE_XRDP" = "1" ]; then
  echo "RDP to the CT IP as a normal user you create with: adduser <you> && usermod -aG sudo <you>"
fi
