#!/bin/bash
set -euo pipefail

# ============================================================
# Wire host devices + the GPU arbiter hookscript into an LXC container.
# Run on the Proxmox host as root. Idempotent.
#
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid>
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid> --no-usb
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid> --remove
#
# WHY THIS IS NOT TERRAFORM: Proxmox restricts BOTH `dev[n]:` (device
# passthrough) and `hookscript:` to root@pam — no role privilege grants them,
# so the API token this project uses gets HTTP 403. Both are set here instead.
#
# What it does, into /etc/pve/lxc/<ctid>.conf:
#   - GPU: exact cgroup2 allows + bind-mounts for /dev/nvidia*, /dev/nvidia-caps/*,
#     /dev/dri/* (majors read live — nvidia-uvm's major is dynamic).
#   - USB/input/sound (unless --no-usb): cgroup majors 189/13/116/166 +
#     bind-mounts of /dev/bus/usb, /dev/input, /dev/snd  -> every USB device,
#     hotplug included (a whole USB *controller* is PCI / VM-only).
#   - hookscript: local:snippets/gpu-arbiter.sh
#   - a host udev rule making usb/input/sound nodes 0666 (an unprivileged CT
#     sees bind-mounted nodes as nobody:nogroup otherwise).
#
# Re-run after any `terraform apply` that recreates the CT.
# ============================================================

CTID="${1:-}"
[ -n "$CTID" ] || { echo "usage: $0 <ctid> [--no-usb|--remove]" >&2; exit 1; }
MODE=add; WITH_USB=1
for a in "${@:2}"; do
  case "$a" in
    --remove) MODE=remove ;;
    --no-usb) WITH_USB=0 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

CONF="/etc/pve/lxc/${CTID}.conf"
[ -f "$CONF" ] || { echo "error: $CONF not found (is the CT created?)" >&2; exit 1; }
HOOK="local:snippets/gpu-arbiter.sh"

BEGIN="# --- workstation passthrough (lxc-ct-passthrough.sh) ---"
END="# --- end workstation passthrough ---"

# --- build the managed block --------------------------------------------
emit_dev() { # $1 = device node path -> cgroup allow + bind mount, by live major:minor
  local n=$1 mm maj min
  [ -e "$n" ] || { echo "#   (skip, absent) $n"; return; }
  mm=$(stat -c '%t %T' "$n")           # hex major minor
  maj=$((16#${mm% *})); min=$((16#${mm#* }))
  echo "lxc.cgroup2.devices.allow: c ${maj}:${min} rwm"
  echo "lxc.mount.entry: ${n} ${n#/} none bind,optional,create=file 0 0"
}

build_block() {
  echo "$BEGIN"
  echo "# GPU"
  local n
  for n in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do emit_dev "$n"; done
  for n in /dev/nvidia-caps/*; do emit_dev "$n"; done
  for n in /dev/dri/card* /dev/dri/renderD*; do emit_dev "$n"; done
  if [ "$WITH_USB" = 1 ]; then
    echo "# USB (189) / input (13) / ALSA (116) / usb-ACM (166)"
    echo "lxc.cgroup2.devices.allow: c 189:* rwm"
    echo "lxc.cgroup2.devices.allow: c 13:* rwm"
    echo "lxc.cgroup2.devices.allow: c 116:* rwm"
    echo "lxc.cgroup2.devices.allow: c 166:* rwm"
    echo "lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0"
    echo "lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir 0 0"
    echo "lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir 0 0"
  fi
  echo "$END"
}

# --- rewrite the conf (exact-line strip of any old block, no regex) -----
tmp=$(mktemp)
awk -v b="$BEGIN" -v e="$END" '
  $0==b { drop=1 } drop==0 { print } $0==e { drop=0 }
' "$CONF" >"$tmp"
[ "$MODE" = add ] && build_block >>"$tmp"

if cmp -s "$tmp" "$CONF"; then
  echo "[conf] $CONF already current"
else
  cat "$tmp" >"$CONF"; echo "[conf] ${MODE}: updated $CONF"
fi
rm -f "$tmp"

# --- hookscript (root@pam only) ----------------------------------------
if [ "$MODE" = add ]; then
  if [ -f /var/lib/vz/snippets/gpu-arbiter.sh ]; then
    pct set "$CTID" --hookscript "$HOOK"
    echo "[hook] pct set $CTID --hookscript $HOOK"
  else
    echo "[hook] WARNING: /var/lib/vz/snippets/gpu-arbiter.sh missing — run install-gpu-arbiter.sh"
  fi
else
  pct set "$CTID" --delete hookscript 2>/dev/null || true
  echo "[hook] removed"
fi

# --- host udev perms for the unprivileged CT ---------------------------
UDEV=/etc/udev/rules.d/99-lxc-workstation-perms.rules
if [ "$MODE" = add ] && [ "$WITH_USB" = 1 ]; then
  cat >"$UDEV" <<'EOF'
SUBSYSTEM=="usb", MODE="0666"
SUBSYSTEM=="input", MODE="0666"
SUBSYSTEM=="sound", MODE="0666"
KERNEL=="ttyACM[0-9]*", MODE="0666"
EOF
  udevadm control --reload && udevadm trigger
  echo "[udev] wrote $UDEV"
elif [ "$MODE" = remove ] && [ -f "$UDEV" ]; then
  rm -f "$UDEV"; udevadm control --reload || true; echo "[udev] removed $UDEV"
fi

echo ""
echo ">>> restart the CT:  pct reboot $CTID   (or: workstation.sh start ubuntu)"
