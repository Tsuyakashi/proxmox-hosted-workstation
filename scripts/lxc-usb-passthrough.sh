#!/bin/bash
set -euo pipefail

# ============================================================
# Give an LXC container ALL host USB + input + sound, hotplug included.
# Run on the Proxmox host. Idempotent.
#
#   ssh bare-pve scripts/lxc-usb-passthrough.sh <ctid>
#   ssh bare-pve scripts/lxc-usb-passthrough.sh <ctid> --remove
#
# A whole USB *controller* is a PCI device and can only go to a VM. A
# container instead gets the /dev subtrees + the matching cgroup device
# allows, which for a workstation is equivalent: every keyboard, mouse,
# headset and stick shows up, and hotplug keeps working.
#
# Terraform (mod/ct.device_passthrough) can't express directory bind-mounts
# or cgroup major ranges, so this is applied out-of-band. Re-run after any
# `terraform apply` that recreates the CT.
# ============================================================

CTID="${1:-}"
[ -n "$CTID" ] || { echo "usage: $0 <ctid> [--remove]" >&2; exit 1; }
MODE=add
[ "${2:-}" = "--remove" ] && MODE=remove

CONF="/etc/pve/lxc/${CTID}.conf"
[ -f "$CONF" ] || { echo "error: $CONF not found (is the CT created?)" >&2; exit 1; }

BEGIN="# --- workstation usb/input/snd passthrough (lxc-usb-passthrough.sh) ---"
END="# --- end workstation usb/input/snd passthrough ---"

# major numbers: 189 usb devices, 13 input (event/mice/js), 116 ALSA, 166 usb-ACM
BLOCK=$(cat <<EOF
${BEGIN}
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.cgroup2.devices.allow: c 166:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir 0 0
${END}
EOF
)

# --- strip any existing managed block (exact line match, no regex) ---------
tmp=$(mktemp)
awk -v b="$BEGIN" -v e="$END" '
  $0==b { drop=1 }
  drop==0 { print }
  $0==e { drop=0 }
' "$CONF" >"$tmp"

if [ "$MODE" = add ]; then
  printf '%s\n' "$BLOCK" >>"$tmp"
fi

if cmp -s "$tmp" "$CONF"; then
  echo "[conf] $CONF already up to date"
  rm -f "$tmp"
else
  cat "$tmp" >"$CONF"           # pmxcfs: write in place, don't rename
  rm -f "$tmp"
  echo "[conf] ${MODE}: updated $CONF"
fi

# --- host udev perms -------------------------------------------------------
# An unprivileged CT sees bind-mounted /dev nodes as nobody:nogroup, so they
# must be world-rw to be usable. Single-purpose workstation host.
UDEV="/etc/udev/rules.d/99-lxc-workstation-perms.rules"
if [ "$MODE" = add ]; then
  cat >"$UDEV" <<'EOF'
# LXC workstation: expose USB / input / sound to the unprivileged container
SUBSYSTEM=="usb", MODE="0666"
SUBSYSTEM=="input", MODE="0666"
SUBSYSTEM=="sound", MODE="0666"
KERNEL=="ttyACM[0-9]*", MODE="0666"
EOF
  udevadm control --reload && udevadm trigger
  echo "[udev] wrote $UDEV and reloaded"
elif [ -f "$UDEV" ]; then
  rm -f "$UDEV"
  udevadm control --reload || true
  echo "[udev] removed $UDEV"
fi

echo ""
echo ">>> restart the CT for the change to take effect:  pct reboot $CTID"
