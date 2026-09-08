#!/bin/bash
set -euo pipefail

# ============================================================
# Apply the root@pam-only bits of the Ubuntu workstation CT.
# Run on the Proxmox node as root. Idempotent.
#
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid>
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid> --no-usb
#   ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid> --remove
#
# WHY NOT TERRAFORM: verified in pve-container src/PVE/LXC.pm — the following
# are `raise_perm_exc(... only allowed for root@pam)` with NO privilege gate,
# so the API token this project uses gets HTTP 403 no matter the role:
#   - dev[n]        device passthrough        (LXC.pm:1710)
#   - hookscript                              (LXC.pm:1761)
#   - features flags other than `nesting`     (check_ct_modify_config_perm)
# The node CLI (`pct set`) runs as root@pam, so it applies all of them.
# Terraform still creates the CT + sets `nesting` (the one token-safe flag).
#
# GPU device nodes go in via the NATIVE `pct set --devN` (Proxmox then handles
# the cgroup allow + mount + unprivileged-CT node perms itself). The USB / input
# / sound *directories* have no `dev[n]` equivalent, so those few lines are
# appended to /etc/pve/lxc/<ctid>.conf raw (the classic pre-8.2 method).
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

FEATURES="${FEATURES:-nesting=1,keyctl=1,fuse=1}"
HOOK="local:snippets/gpu-arbiter.sh"
CONF="/etc/pve/lxc/${CTID}.conf"
[ -f "$CONF" ] || { echo "error: $CONF not found (is the CT created?)" >&2; exit 1; }

GPU_NODES=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools
           /dev/dri/card0 /dev/dri/renderD128)
for n in /dev/nvidia-caps/nvidia-cap*; do [ -e "$n" ] && GPU_NODES+=("$n"); done

BEGIN="# --- workstation usb/input/snd passthrough (lxc-ct-passthrough.sh) ---"
END="# --- end workstation usb/input/snd passthrough ---"

pct_running() { pct status "$CTID" 2>/dev/null | grep -q running; }
if pct_running; then
  echo "note: CT $CTID is running — changes apply on its next start" >&2
fi

# ------------------------------------------------------------
# 1. GPU device nodes -> native `pct set --devN`
# ------------------------------------------------------------
# Wipe any devN we manage, then re-add. (Proxmox has no "list my devN", so we
# clear a generous range and rebuild deterministically from index 0.)
if [ "$MODE" = add ]; then
  DEL=(); for i in $(seq 0 31); do grep -q "^dev${i}:" "$CONF" && DEL+=("dev${i}"); done
  [ "${#DEL[@]}" -gt 0 ] && pct set "$CTID" --delete "$(IFS=,; echo "${DEL[*]}")" >/dev/null || true
  i=0
  for n in "${GPU_NODES[@]}"; do
    [ -e "$n" ] || { echo "  skip (absent): $n"; continue; }
    pct set "$CTID" "--dev${i}" "${n},mode=0666" >/dev/null
    echo "  dev${i} = ${n}"
    i=$((i + 1))
  done
else
  DEL=(); for i in $(seq 0 31); do grep -q "^dev${i}:" "$CONF" && DEL+=("dev${i}"); done
  [ "${#DEL[@]}" -gt 0 ] && pct set "$CTID" --delete "$(IFS=,; echo "${DEL[*]}")" >/dev/null || true
  echo "  removed all devN"
fi

# ------------------------------------------------------------
# 2. features (keyctl/fuse — nesting is already set by Terraform)
# ------------------------------------------------------------
if [ "$MODE" = add ]; then
  pct set "$CTID" --features "$FEATURES" >/dev/null
  echo "  features = $FEATURES"
else
  pct set "$CTID" --features nesting=1 >/dev/null || true
  echo "  features = nesting=1"
fi

# ------------------------------------------------------------
# 3. hookscript
# ------------------------------------------------------------
if [ "$MODE" = add ]; then
  if [ -f /var/lib/vz/snippets/gpu-arbiter.sh ]; then
    pct set "$CTID" --hookscript "$HOOK" >/dev/null
    echo "  hookscript = $HOOK"
  else
    echo "  WARNING: /var/lib/vz/snippets/gpu-arbiter.sh missing — run install-gpu-arbiter.sh"
  fi
else
  pct set "$CTID" --delete hookscript >/dev/null 2>&1 || true
  echo "  hookscript removed"
fi

# ------------------------------------------------------------
# 4. USB / input / sound directories (no dev[n] equivalent) -> raw lxc.*
# ------------------------------------------------------------
tmp=$(mktemp)
awk -v b="$BEGIN" -v e="$END" '$0==b{drop=1} drop==0{print} $0==e{drop=0}' "$CONF" >"$tmp"
if [ "$MODE" = add ] && [ "$WITH_USB" = 1 ]; then
  cat >>"$tmp" <<EOF
$BEGIN
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.cgroup2.devices.allow: c 166:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir 0 0
$END
EOF
fi
cmp -s "$tmp" "$CONF" || { cat "$tmp" >"$CONF"; echo "  usb/input/snd raw lxc.*: ${MODE}"; }
rm -f "$tmp"

# host udev perms — an unprivileged CT sees bind-mounted nodes as nobody:nogroup
UDEV=/etc/udev/rules.d/99-lxc-workstation-perms.rules
if [ "$MODE" = add ] && [ "$WITH_USB" = 1 ]; then
  cat >"$UDEV" <<'EOF'
SUBSYSTEM=="usb", MODE="0666"
SUBSYSTEM=="input", MODE="0666"
SUBSYSTEM=="sound", MODE="0666"
KERNEL=="ttyACM[0-9]*", MODE="0666"
EOF
  udevadm control --reload && udevadm trigger
  echo "  udev: $UDEV"
elif [ "$MODE" = remove ] && [ -f "$UDEV" ]; then
  rm -f "$UDEV"; udevadm control --reload || true; echo "  udev: removed"
fi

echo ""
echo ">>> (re)start the CT:  pct reboot $CTID   or   workstation.sh start ubuntu"
