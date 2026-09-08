#!/bin/bash
set -euo pipefail

# ============================================================
# Proxmox host prep for an LXC workstation that SHARES the GPU
# (device-node passthrough, host kernel driver). Idempotent.
# ============================================================
#
# This is the MIRROR IMAGE of scripts/iommu-vfio-setup.sh:
#   iommu-vfio-setup.sh  -> GPU bound to vfio-pci, host driver blacklisted
#                           (for env/windows: a real PCI-passthrough VM)
#   this script          -> GPU bound to the NVIDIA driver on the host,
#                           vfio-pci binding removed
#                           (for env/ubuntu: an LXC that opens /dev/nvidia*)
#
# You cannot have both at once. Run this, reboot, then `terraform -chdir=
# env/ubuntu apply`. To go back to the Windows VM: run iommu-vfio-setup.sh,
# reboot, `terraform -chdir=env/windows apply`.
#
#   ssh bare-pve 'NVIDIA_VERSION=580.xx.xx bash -s' < scripts/lxc-nvidia-host-setup.sh
#
# NVIDIA_VERSION: a Linux x86_64 driver build. The GTX 950 is Maxwell — the
# 580 branch is the LAST one that supports it. Pick the exact build from
#   https://download.nvidia.com/XFree86/Linux-x86_64/
# The container's userspace driver (lxc-ubuntu-desktop-provision.sh) MUST match
# this version exactly.

NVIDIA_VERSION="${NVIDIA_VERSION:-}"
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

if [ -z "$NVIDIA_VERSION" ]; then
  echo "error: set NVIDIA_VERSION (e.g. NVIDIA_VERSION=580.82.09). See header." >&2
  exit 1
fi

REBOOT_REQUIRED=false
CHANGES=()

note() { CHANGES+=("$1"); echo "[change] $1"; }

# ------------------------------------------------------------
# 1. Undo any vfio-pci capture of the GPU
# ------------------------------------------------------------
# iommu-vfio-setup.sh writes these; strip the NVIDIA bits so the host driver
# can bind. USB/onboard-audio vfio lines are left alone (harmless here, and
# env/windows still wants them).
VFIO_CONF="/etc/modprobe.d/vfio.conf"
if [ -f "$VFIO_CONF" ] && grep -q "10de:" "$VFIO_CONF"; then
  sed -i.bak -E 's/(ids=)?10de:[0-9a-f]{4},?//g; s/,\s*$//; /options vfio-pci ids=\s*$/d' "$VFIO_CONF"
  note "removed NVIDIA ids from $VFIO_CONF"
  REBOOT_REQUIRED=true
fi

SOFTDEP_CONF="/etc/modprobe.d/vfio-softdep.conf"
if [ -f "$SOFTDEP_CONF" ] && grep -qE 'softdep (nvidia|nouveau|nvidiafb)' "$SOFTDEP_CONF"; then
  sed -i.bak -E '/softdep (nvidia|nouveau|nvidiafb) pre: vfio-pci/d' "$SOFTDEP_CONF"
  note "removed nvidia/nouveau softdep from $SOFTDEP_CONF"
  REBOOT_REQUIRED=true
fi

# ------------------------------------------------------------
# 2. Blacklist nouveau only (we want the proprietary driver)
# ------------------------------------------------------------
BLACKLIST_CONF="/etc/modprobe.d/blacklist-nouveau.conf"
declare -A WANT_BLACKLIST=( [nouveau]=1 )
# make sure the vfio blacklist file isn't still killing nvidia
if [ -f /etc/modprobe.d/blacklist.conf ] && grep -qxF "blacklist nvidia" /etc/modprobe.d/blacklist.conf; then
  sed -i.bak -E '/^blacklist (nvidia|nvidiafb)$/d' /etc/modprobe.d/blacklist.conf
  note "un-blacklisted nvidia in /etc/modprobe.d/blacklist.conf"
  REBOOT_REQUIRED=true
fi
for m in "${!WANT_BLACKLIST[@]}"; do
  L="blacklist $m"
  if [ -f "$BLACKLIST_CONF" ] && grep -qxF "$L" "$BLACKLIST_CONF"; then
    echo "[blacklist] $m already present"
  else
    echo "$L" >> "$BLACKLIST_CONF"
    note "blacklist $m"
    REBOOT_REQUIRED=true
  fi
done

# ------------------------------------------------------------
# 3. Build toolchain + kernel headers (DKMS needs them)
# ------------------------------------------------------------
NEED_PKGS=()
for p in build-essential dkms "proxmox-headers-$(uname -r)" pve-headers; do
  dpkg -s "$p" &>/dev/null || NEED_PKGS+=("$p")
done
if [ "${#NEED_PKGS[@]}" -gt 0 ]; then
  # pve-headers is a metapackage; proxmox-headers-<ver> is the exact one. Try
  # both, ignore the one that doesn't resolve on this release.
  apt-get update
  apt-get install -y build-essential dkms "proxmox-headers-$(uname -r)" || \
    apt-get install -y build-essential dkms pve-headers
  note "installed build toolchain + kernel headers"
fi

# ------------------------------------------------------------
# 4. NVIDIA driver via the .run installer (DKMS, no X, no 32-bit libs)
# ------------------------------------------------------------
INSTALLED_VER="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
if [ "$INSTALLED_VER" = "$NVIDIA_VERSION" ]; then
  echo "[nvidia] driver $NVIDIA_VERSION already loaded"
else
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  [ -f "$RUN" ] || curl -fL -o "$RUN" "${RUN_URL_BASE}/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  sh "$RUN" --silent --dkms --no-opengl-files --no-x-check --no-nouveau-check --no-questions
  note "installed NVIDIA driver $NVIDIA_VERSION (dkms)"
  REBOOT_REQUIRED=true
fi

# ------------------------------------------------------------
# 5. Autoload modules + persistence so /dev/nvidia* exist at boot
#    (no X server on a Proxmox host to create them lazily)
# ------------------------------------------------------------
MODLOAD="/etc/modules-load.d/nvidia.conf"
printf '%s\n' nvidia nvidia_modeset nvidia_uvm nvidia_drm > "${MODLOAD}.new"
if ! cmp -s "${MODLOAD}.new" "$MODLOAD" 2>/dev/null; then
  mv "${MODLOAD}.new" "$MODLOAD"; note "wrote $MODLOAD"; REBOOT_REQUIRED=true
else
  rm -f "${MODLOAD}.new"
fi

DRMOPT="/etc/modprobe.d/nvidia-drm.conf"
LINE="options nvidia-drm modeset=1"
if ! { [ -f "$DRMOPT" ] && grep -qxF "$LINE" "$DRMOPT"; }; then
  echo "$LINE" > "$DRMOPT"; note "wrote $DRMOPT"; REBOOT_REQUIRED=true
fi

# nvidia-persistenced keeps the GPU initialised (and the uvm/modeset nodes
# present) with no display attached. The .run installer ships the unit.
if systemctl list-unit-files | grep -q '^nvidia-persistenced.service'; then
  systemctl enable --now nvidia-persistenced.service || true
fi

# udev fallback for the uvm device nodes (some setups race persistenced)
UDEV="/etc/udev/rules.d/70-nvidia-uvm.rules"
if [ ! -f "$UDEV" ]; then
  cat > "$UDEV" <<'EOF'
KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -c0 -u"
EOF
  note "wrote $UDEV"
fi

# ------------------------------------------------------------
# 6. initramfs + summary
# ------------------------------------------------------------
if [ "$REBOOT_REQUIRED" = true ]; then
  update-initramfs -u -k all
fi

echo ""
echo "=== Summary ==="
if [ "${#CHANGES[@]}" -eq 0 ]; then
  echo "No changes. Host already set for LXC GPU sharing."
else
  printf '  - %s\n' "${CHANGES[@]}"
fi

echo ""
if [ "$REBOOT_REQUIRED" = true ]; then
  echo ">>> REBOOT REQUIRED. After reboot verify:"
  echo "    lspci -k -s 01:00.0        # 'Kernel driver in use: nvidia'"
  echo "    nvidia-smi                  # lists the GTX 950"
  echo "    ls -l /dev/nvidia* /dev/dri # nodes present"
else
  echo "No reboot needed."
fi
