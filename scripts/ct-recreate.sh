#!/bin/bash
set -euo pipefail

# ============================================================
# Create the env/ubuntu workstation CT as a PRIVILEGED container.
# Run on the Proxmox node as root.
#
#   ssh bare-pve scripts/ct-recreate.sh [ctid]        # default 101
#
# WHY THIS EXISTS: env/ubuntu needs a privileged CT (a real GNOME/GDM desktop
# wants systemd-logind graphical sessions + a working udev, which unprivileged
# Proxmox CTs don't provide). Creating a privileged CT over the API needs
# `Sys.Modify` on `/`, which the project's token deliberately lacks — so
# `terraform apply` fails at create with HTTP 403. This script is the
# root@pam node-side equivalent; afterwards reconcile Terraform state with:
#
#   cd env/ubuntu && terraform import \
#     module.ubuntu_ct.proxmox_virtual_environment_container.this bare-pve/<ctid>
#
# Then run scripts/lxc-ct-passthrough.sh <ctid> for the GPU/USB/seat/hookscript
# bits, and provision inside with scripts/lxc-ubuntu-desktop-provision.sh.
#
# Keep the params here in sync with env/ubuntu (mod/ct + variables.tf).
# ============================================================

CTID="${1:-101}"
TEMPLATE="${TEMPLATE:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"

# env/ubuntu defaults
HOSTNAME_="ubuntu-workstation"
CORES=4
MEMORY=12288
SWAP=0
DISK_GB=64
BRIDGE=vmbr0
MAC="BC:24:11:AB:CD:01"
NAMESERVERS="192.168.100.1 8.8.8.8 1.1.1.1"
SEARCHDOMAIN=lan

if pct status "$CTID" &>/dev/null; then
  echo "CT $CTID already exists. To rebuild from scratch:"
  echo "  pct stop $CTID 2>/dev/null; pct destroy $CTID --purge"
  echo "  (then re-run this script)"
  exit 1
fi

if ! pveam list local | grep -q "${TEMPLATE##*/}"; then
  echo "template ${TEMPLATE##*/} not on 'local' — downloading"
  pveam update
  pveam download local "${TEMPLATE##*/}"
fi

pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME_" \
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
  --rootfs "local-lvm:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},hwaddr=${MAC},ip=dhcp" \
  --nameserver "$NAMESERVERS" \
  --searchdomain "$SEARCHDOMAIN" \
  --ostype ubuntu \
  --unprivileged 0 \
  --features nesting=1,keyctl=1,fuse=1 \
  --onboot 0 \
  --tags "workstation;gpu;ubuntu" \
  --start 0

echo
echo "=== created (privileged) ==="
pct config "$CTID"
echo
echo "next:"
echo "  1. cd env/ubuntu && terraform import module.ubuntu_ct.proxmox_virtual_environment_container.this bare-pve/$CTID"
echo "  2. ssh bare-pve scripts/lxc-ct-passthrough.sh $CTID"
echo "  3. pct push $CTID scripts/lxc-ubuntu-desktop-provision.sh /root/provision.sh && \\"
echo "     pct start $CTID && pct exec $CTID -- bash /root/provision.sh"
