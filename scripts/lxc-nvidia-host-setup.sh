#!/bin/bash
set -euo pipefail

# ============================================================
# Proxmox host prep for an LXC workstation that SHARES the GPU
# (device-node passthrough, host kernel driver). Idempotent.
# ============================================================
#
# MIRROR IMAGE of scripts/iommu-vfio-setup.sh:
#   iommu-vfio-setup.sh  -> GPU on vfio-pci, host nvidia driver blacklisted
#                           (env/windows: a real PCI-passthrough VM)
#   this script          -> proprietary NVIDIA driver on the host, GPU freed
#                           from vfio-pci (env/ubuntu: an LXC opening /dev/nvidia*)
#
# Both can't be active at once. Run this once; afterwards the GPU is flipped
# between vfio-pci and nvidia at RUNTIME by scripts/gpu-arbiter.sh (no reboot).
#
#   ssh bare-pve 'NVIDIA_VERSION=580.178.04 bash -s' < scripts/lxc-nvidia-host-setup.sh
#
# The GTX 950 is Maxwell -> the 580 branch is the LAST with support; use the
# PROPRIETARY module (open modules are Turing+ only). Verified building &
# loading on PVE 9.2 kernel 7.0.2-6-pve with 580.178.04. The container's
# userspace driver (lxc-ubuntu-desktop-provision.sh) MUST match this version.

NVIDIA_VERSION="${NVIDIA_VERSION:-580.178.04}"
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"
GPU_FUNCS=(0000:01:00.0 0000:01:00.1)

CHANGES=()
note() { CHANGES+=("$1"); echo "[change] $1"; }

# ------------------------------------------------------------
# 1. apt: pve-no-subscription (the enterprise repo needs a paid key; without
#    it kernel headers for DKMS are unreachable)
# ------------------------------------------------------------
NOSUB=/etc/apt/sources.list.d/pve-no-subscription.sources
if [ ! -f "$NOSUB" ]; then
  cat > "$NOSUB" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  for f in pve-enterprise ceph; do
    [ -f "/etc/apt/sources.list.d/$f.sources" ] && \
      grep -q '^Enabled: false' "/etc/apt/sources.list.d/$f.sources" || \
      sed -i 's|^Types: deb|Types: deb\nEnabled: false|' "/etc/apt/sources.list.d/$f.sources" 2>/dev/null || true
  done
  note "added pve-no-subscription repo"
fi
apt-get update -qq

# ------------------------------------------------------------
# 2. Build toolchain + kernel headers
# ------------------------------------------------------------
NEED=()
for p in build-essential dkms "proxmox-headers-$(uname -r)"; do
  dpkg -s "$p" &>/dev/null || NEED+=("$p")
done
if [ "${#NEED[@]}" -gt 0 ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${NEED[@]}"
  note "installed ${NEED[*]}"
fi

# ------------------------------------------------------------
# 3. Driver conflicts: blacklist nouveau + nova_core (the in-tree Rust nvidia
#    driver), un-blacklist the proprietary nvidia, drop vfio softdep for it,
#    strip the GPU ids from vfio.conf (USB/onboard-audio ids stay).
# ------------------------------------------------------------
BL=/etc/modprobe.d/blacklist.conf
touch "$BL"
sed -i '/^blacklist nvidia$/d; /^blacklist nvidiafb$/d' "$BL"
for m in nouveau nova_core; do
  grep -qxF "blacklist $m" "$BL" || { echo "blacklist $m" >> "$BL"; note "blacklist $m"; }
done

SD=/etc/modprobe.d/vfio-softdep.conf
if [ -f "$SD" ] && grep -qE 'softdep (nvidia|nvidiafb) pre: vfio-pci' "$SD"; then
  sed -i '/softdep nvidia pre: vfio-pci/d; /softdep nvidiafb pre: vfio-pci/d' "$SD"
  note "removed nvidia softdep"
fi

VFIO=/etc/modprobe.d/vfio.conf
if [ -f "$VFIO" ] && grep -qE '10de:(1402|0fba)' "$VFIO"; then
  sed -i -E 's/10de:1402,?//g; s/10de:0fba,?//g; s/,\s*$//' "$VFIO"
  note "removed GPU ids from vfio.conf"
fi
depmod -a

# ------------------------------------------------------------
# 4. Free the GPU from vfio-pci so the installer can load onto it.
#    Refuse if the Windows VM is running.
# ------------------------------------------------------------
if qm list 2>/dev/null | awk '$2=="windows-workstation"{print $3}' | grep -q running; then
  echo "error: windows-workstation VM is running — stop it before taking the GPU" >&2
  exit 1
fi
for d in "${GPU_FUNCS[@]}"; do
  printf '\n' > "/sys/bus/pci/devices/$d/driver_override" 2>/dev/null || true
  [ -L "/sys/bus/pci/devices/$d/driver" ] && echo "$d" > "/sys/bus/pci/devices/$d/driver/unbind" || true
done

# ------------------------------------------------------------
# 5. NVIDIA driver via the .run installer (proprietary module, DKMS)
# ------------------------------------------------------------
if [ "$(cat /sys/module/nvidia/version 2>/dev/null || true)" = "$NVIDIA_VERSION" ]; then
  echo "[nvidia] $NVIDIA_VERSION already loaded"
else
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  [ -f "$RUN" ] || curl -fL --progress-bar -o "$RUN" "${RUN_URL_BASE}/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  sh "$RUN" --silent --dkms --no-opengl-files --no-x-check --no-nouveau-check --no-questions
  note "installed NVIDIA driver $NVIDIA_VERSION (dkms)"
fi

# ------------------------------------------------------------
# 6. Autoload + device nodes without an X server
# ------------------------------------------------------------
printf '%s\n' nvidia nvidia_modeset nvidia_uvm nvidia_drm > /etc/modules-load.d/nvidia.conf
echo 'options nvidia-drm modeset=1' > /etc/modprobe.d/nvidia-drm.conf
cat > /etc/udev/rules.d/70-nvidia.rules <<'EOF'
KERNEL=="nvidia", RUN+="/usr/bin/nvidia-modprobe -c0"
KERNEL=="nvidia_modeset", RUN+="/usr/bin/nvidia-modprobe -c0 -m"
KERNEL=="nvidia_uvm", RUN+="/usr/bin/nvidia-modprobe -c0 -u"
EOF
udevadm control --reload || true
nvidia-modprobe -c0 -u -m 2>/dev/null || true
systemctl list-unit-files | grep -q '^nvidia-persistenced.service' && \
  systemctl enable --now nvidia-persistenced.service 2>/dev/null || true
update-initramfs -u -k all 2>&1 | tail -1 || true

# ------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------
echo ""
echo "=== Summary ==="
[ "${#CHANGES[@]}" -eq 0 ] && echo "no changes" || printf '  - %s\n' "${CHANGES[@]}"
echo ""
echo "verify:"
echo "  nvidia-smi"
echo "  /var/lib/vz/snippets/gpu-arbiter.sh status   # host mode -> ubuntu"
echo "  ls -l /dev/nvidia* /dev/dri"
