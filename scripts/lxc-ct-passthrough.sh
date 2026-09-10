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
#   - creating a PRIVILEGED CT at all         (needs Sys.Modify on /)
# The node CLI (`pct create` / `pct set`) runs as root@pam, so it does all of
# it. env/ubuntu is a PRIVILEGED CT (a real GNOME/GDM desktop needs
# systemd-logind sessions + udev, which unprivileged Proxmox CTs don't give);
# Terraform can't create it, so scripts/ct-recreate.sh does, then
# `terraform import` reconciles state. This script then layers on:
#   - features nesting/keyctl/fuse
#   - lxc.apparmor.profile: unconfined   (GDM/mutter/logind/snapd trip the
#     default + nesting profiles; single-user box, accepted)
#   - the GPU / USB / input / sound / seat (fb + VTs) device lines
#   - the gpu-arbiter hookscript
#
# EVERYTHING device-related goes in as raw `lxc.mount.entry ... bind,optional`
# + `lxc.cgroup2.devices.allow`, NOT `pct set --devN`. `dev[n]` paths are
# validated by `pct start` BEFORE the pre-start hook runs, so with the GPU
# still on vfio-pci a plain start / web-UI Start fails ("Device ... does not
# exist") and the arbiter never gets to rebind. Raw lxc lines are not
# pre-validated; the hook (host ns, runs first) creates the nodes, then lxc
# binds them. Host udev makes the nodes 0666 (unprivileged CT sees bind mounts
# as nobody:nogroup otherwise).
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

BEGIN="# --- workstation seat: usb/input/snd + physical console (lxc-ct-passthrough.sh) ---"
END="# --- end workstation seat ---"
# older marker (pre-seat) — also stripped so upgrades are clean
OLD_BEGIN="# --- workstation usb/input/snd passthrough (lxc-ct-passthrough.sh) ---"
OLD_END="# --- end workstation usb/input/snd passthrough ---"

pct_running() { pct status "$CTID" 2>/dev/null | grep -q running; }
if pct_running; then
  echo "note: CT $CTID is running — changes apply on its next start" >&2
fi

# ------------------------------------------------------------
# 1. drop any `dev[n]:` — the GPU goes in via raw lxc.mount.entry (section 4)
# ------------------------------------------------------------
# WHY NOT `pct set --devN`: `pct start` (and the web-UI Start button) validate
# every dev[n] PATH before invoking lxc-start — i.e. before the gpu-arbiter
# pre-start hook can rebind the card to nvidia. So on a plain start with the
# GPU still on vfio-pci you get `TASK ERROR: Device /dev/dri/card0 does not
# exist` and the hook never runs. Raw `lxc.mount.entry ... bind,optional` is
# NOT pre-validated: lxc parses it, the pre-start hook (which runs first, in
# the host ns) rebinds + creates the nodes, then lxc's mount phase binds them.
DEL=(); for i in $(seq 0 31); do grep -q "^dev${i}:" "$CONF" && DEL+=("dev${i}"); done
[ "${#DEL[@]}" -gt 0 ] && pct set "$CTID" --delete "$(IFS=,; echo "${DEL[*]}")" >/dev/null || true
[ "${#DEL[@]}" -gt 0 ] && echo "  removed ${#DEL[@]} dev[n] entries"

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
# 4. Raw lxc.* — things dev[n] can't express:
#    - USB / input / sound *directories* (bind + cgroup major ranges)
#    - the physical seat: framebuffer + VTs so an Xorg inside the CT can
#      become DRM-master and light the monitors. NOTE: never bind /dev/console
#      or /dev/tty0 — LXC owns those and it fails the container with
#      `sync_wait: 34`. tty1/tty2/tty7 + fb0 are enough (Xorg runs with
#      -keeptty, so it never VT-switches).
# ------------------------------------------------------------
tmp=$(mktemp)
awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" '
  $0==b || $0==ob {drop=1} drop==0{print} $0==e || $0==oe {drop=0}' "$CONF" >"$tmp"
if [ "$MODE" = add ] && [ "$WITH_USB" = 1 ]; then
  cat >>"$tmp" <<EOF
$BEGIN
# Privileged CT for a full GNOME desktop. The default (and nesting) AppArmor
# profiles block enough of GDM / mutter / systemd-logind / snapd that the
# session never comes up; unconfine it (single-user workstation, own box).
lxc.apparmor.profile: unconfined
# GPU: nvidia (195), drm (226), nvidia-caps (236). nvidia-uvm's major is
# DYNAMIC (kernel allocates it high) — allow a range that covers it (seen
# 509/511); if it lands outside 505-511 after a host reboot, widen this.
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 234:* rwm
lxc.cgroup2.devices.allow: c 235:* rwm
lxc.cgroup2.devices.allow: c 236:* rwm
lxc.cgroup2.devices.allow: c 237:* rwm
lxc.cgroup2.devices.allow: c 505:* rwm
lxc.cgroup2.devices.allow: c 506:* rwm
lxc.cgroup2.devices.allow: c 507:* rwm
lxc.cgroup2.devices.allow: c 508:* rwm
lxc.cgroup2.devices.allow: c 509:* rwm
lxc.cgroup2.devices.allow: c 510:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file 0 0
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file 0 0
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file 0 0
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file 0 0
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir 0 0
# USB (189) / input (13) / ALSA (116) / usb-ACM (166) / tty (4) / fb (29) / uinput (10:223)
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.cgroup2.devices.allow: c 166:* rwm
lxc.cgroup2.devices.allow: c 4:* rwm
lxc.cgroup2.devices.allow: c 29:* rwm
lxc.cgroup2.devices.allow: c 10:223 rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir 0 0
lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/vga_arbiter dev/vga_arbiter none bind,optional,create=file 0 0
lxc.mount.entry: /dev/uinput dev/uinput none bind,optional,create=file 0 0
# VTs for GDM/Xorg. Xorg runs -keeptty -novtswitch; GDM's logind seat wants a
# few. NEVER bind /dev/console or /dev/tty0 — LXC owns them (sync_wait: 34).
lxc.mount.entry: /dev/tty1 dev/tty1 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/tty2 dev/tty2 none bind,optional,create=file 0 0
lxc.mount.entry: /dev/tty7 dev/tty7 none bind,optional,create=file 0 0
$END
EOF
fi
cmp -s "$tmp" "$CONF" || { cat "$tmp" >"$CONF"; echo "  raw lxc.* seat block: ${MODE}"; }
rm -f "$tmp"

# host udev perms — an unprivileged CT sees bind-mounted nodes as nobody:nogroup
UDEV=/etc/udev/rules.d/99-lxc-workstation-perms.rules
if [ "$MODE" = add ] && [ "$WITH_USB" = 1 ]; then
  cat >"$UDEV" <<'EOF'
SUBSYSTEM=="usb", MODE="0666"
SUBSYSTEM=="input", MODE="0666"
SUBSYSTEM=="sound", MODE="0666"
SUBSYSTEM=="graphics", MODE="0666"
KERNEL=="ttyACM[0-9]*", MODE="0666"
KERNEL=="tty[0-9]*", MODE="0666"
KERNEL=="fb[0-9]*", MODE="0666"
KERNEL=="vga_arbiter", MODE="0666"
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", MODE="0666"
KERNEL=="renderD[0-9]*", SUBSYSTEM=="drm", MODE="0666"
EOF
  udevadm control --reload && udevadm trigger
  echo "  udev: $UDEV"
elif [ "$MODE" = remove ] && [ -f "$UDEV" ]; then
  rm -f "$UDEV"; udevadm control --reload || true; echo "  udev: removed"
fi

echo ""
echo ">>> (re)start the CT:  pct reboot $CTID   or   workstation.sh start ubuntu"
