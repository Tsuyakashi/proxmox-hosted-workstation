#!/bin/bash
set -uo pipefail

# ============================================================
# workstation.sh — single-GPU mutual-exclusion lock + driver swap
# ============================================================
#
# bare-pve has ONE discrete GPU and one set of USB controllers, shared by two
# mutually-exclusive guests:
#
#   windows -> PCI-passthrough VM   GPU + USB functions bound to vfio-pci
#   ubuntu  -> LXC container        GPU on nvidia, USB on native drivers
#                                   (+ /dev shared into the CT)
#
# Model (what the user asked for):
#   * Both guests default OFF — on_boot=false / start_on_boot=false.
#   * Stopping one guest never starts the other. Nothing auto-chains.
#   * `start <guest>` is the ONLY trigger. It:
#       1. takes an flock (serialises switches),
#       2. refuses if the OTHER guest is running (--force to stop it first),
#       3. checks which driver currently owns the GPU,
#       4. swaps GPU + USB bindings to the target's mode IF NEEDED
#          (live PCI rebind; `--via-reboot` for the rare busy case),
#       5. starts the target guest.
#   * `switch <guest>` does step 3-4 only (swap, don't start).
#   * `stop [guest]` shuts guest(s) down and leaves the host as-is.
#
# Run on the Proxmox host as root:
#   ssh bare-pve scripts/workstation.sh status
#   ssh bare-pve scripts/workstation.sh start ubuntu
#   ssh bare-pve scripts/workstation.sh start windows --force
#
# Override discovery via env: WIN_NAME, CT_NAME, GPU_VGA, GPU_AUD, USB_FUNCS.

# ---- site config ------------------------------------------------------------
WIN_NAME="${WIN_NAME:-windows-workstation}"
CT_NAME="${CT_NAME:-ubuntu-workstation}"

GPU_VGA="${GPU_VGA:-0000:01:00.0}"
GPU_AUD="${GPU_AUD:-0000:01:00.1}"
read -r -a USB_FUNCS <<<"${USB_FUNCS:-0000:00:14.0 0000:00:1d.0 0000:00:1a.0 0000:00:1b.0}"
NVIDIA_MODS=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

STATE_DIR=/var/lib/workstation
LOCK_FILE=/run/lock/workstation.lock
PENDING_FILE="$STATE_DIR/pending-start"
OWNER_FILE="$STATE_DIR/owner"

# ---- helpers ---------------------------------------------------------------
die()  { echo "error: $*" >&2; exit 1; }
info() { echo "[workstation] $*"; }

need_root() { [ "$(id -u)" = 0 ] || die "must run as root (on the Proxmox host)"; }

take_lock() {
  exec 9>"$LOCK_FILE"
  flock -w 300 9 || die "another workstation.sh operation is in progress"
}

# vmid lookup by the name written in the guest config (robust vs. qm/pct table
# parsing).
win_vmid() { grep -sl "^name: ${WIN_NAME}\$"     /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
ct_vmid()  { grep -sl "^hostname: ${CT_NAME}\$"  /etc/pve/lxc/*.conf         2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }

vm_running() { [ -n "${1:-}" ] && qm  status "$1" 2>/dev/null | grep -q running; }
ct_running() { [ -n "${1:-}" ] && pct status "$1" 2>/dev/null | grep -q running; }

cur_driver() { # $1 = 0000:BB:DD.F
  local l="/sys/bus/pci/devices/$1/driver"
  if [ -L "$l" ]; then basename "$(readlink -f "$l")"; else echo "(none)"; fi
}

host_mode() {
  case "$(cur_driver "$GPU_VGA")" in
    vfio-pci) echo windows ;;
    nvidia)   echo ubuntu  ;;
    *)        echo unknown ;;
  esac
}

write_owner() { mkdir -p "$STATE_DIR"; echo "${1}" >"$OWNER_FILE"; }

# ---- PCI rebind ----------------------------------------------------------
_unbind() {
  local d=$1 drv; drv=$(cur_driver "$d")
  [ "$drv" = "(none)" ] && return 0
  echo "$d" >"/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null || return 1
}

bind_to() { # $1 device, $2 target driver ("" = clear override, kernel default match)
  local d=$1 target=${2:-} ovr="/sys/bus/pci/devices/$1/driver_override"
  if [ -n "$target" ]; then printf '%s\n' "$target" >"$ovr" 2>/dev/null || true
  else printf '\n' >"$ovr" 2>/dev/null || true
  fi
  _unbind "$d" || { info "  $d busy (held by $(cur_driver "$d")) — cannot rebind"; return 1; }
  printf '%s\n' "$d" >/sys/bus/pci/drivers_probe 2>/dev/null || true
  return 0
}

switch_to_windows() {
  info "binding GPU + USB to vfio-pci"
  systemctl stop nvidia-persistenced 2>/dev/null || true
  modprobe vfio-pci 2>/dev/null || modprobe vfio_pci 2>/dev/null || true
  local d rc=0
  for d in "$GPU_VGA" "$GPU_AUD" "${USB_FUNCS[@]}"; do
    bind_to "$d" vfio-pci || rc=1
  done
  [ "$(cur_driver "$GPU_VGA")" = vfio-pci ] || rc=1
  return $rc
}

switch_to_ubuntu() {
  info "binding GPU to nvidia, USB back to native drivers"
  modprobe "${NVIDIA_MODS[@]}" 2>/dev/null || true
  local d rc=0
  bind_to "$GPU_VGA" nvidia || rc=1
  bind_to "$GPU_AUD" ""     || rc=1           # snd_hda_intel
  for d in "${USB_FUNCS[@]}"; do
    bind_to "$d" "" || rc=1                   # xhci_pci / ehci-pci / snd_hda_intel
  done
  nvidia-modprobe -c0 -u 2>/dev/null || true  # (re)create /dev/nvidia-uvm* w/o X
  systemctl start nvidia-persistenced 2>/dev/null || true
  [ "$(cur_driver "$GPU_VGA")" = nvidia ] || rc=1
  return $rc
}

do_switch() { # $1 target  $2 via_reboot(0/1)
  local target=$1 via_reboot=${2:-0} from
  from=$(host_mode)
  if [ "$from" = "$target" ]; then info "host already in $target mode"; return 0; fi

  if [ "$via_reboot" = 1 ]; then
    mkdir -p "$STATE_DIR"; echo "$target" >"$PENDING_FILE"
    info "reboot requested — workstation-resume.service will finish the switch to $target after boot"
    systemctl reboot
    exit 0
  fi

  info "swapping host $from -> $target (live)"
  local rc=0
  if [ "$target" = windows ]; then switch_to_windows || rc=$?; else switch_to_ubuntu || rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    echo >&2
    echo "error: live rebind to $target failed — a device is still held" >&2
    echo "       (VM/CT not fully stopped, nvidia-persistenced, or an Xorg on the host)." >&2
    echo "       Retry after a reboot:  $0 switch $target --via-reboot" >&2
    return 1
  fi
  info "host now in $target mode"
}

# ---- commands ------------------------------------------------------------
cmd_status() {
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  echo "host mode      : $(host_mode)   (GPU driver: $(cur_driver "$GPU_VGA"))"
  echo "owner record   : $(cat "$OWNER_FILE" 2>/dev/null || echo none)"
  echo "windows VM     : id=${win:-not-created}  $(vm_running "$win" && echo RUNNING || echo stopped)"
  echo "ubuntu  CT     : id=${ct:-not-created}  $(ct_running "$ct" && echo RUNNING || echo stopped)"
  [ -f "$PENDING_FILE" ] && echo "pending switch : $(cat "$PENDING_FILE")"
  echo
  echo "PCI function -> driver:"
  local d
  for d in "$GPU_VGA" "$GPU_AUD" "${USB_FUNCS[@]}"; do
    printf '  %s  %s\n' "$d" "$(cur_driver "$d")"
  done
}

cmd_stop() {
  local which=${1:-both}
  take_lock
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  case "$which" in
    windows|ubuntu|both) ;;
    *) die "stop [windows|ubuntu]" ;;
  esac
  if [ "$which" != ubuntu ] && vm_running "$win"; then
    info "shutting down windows VM $win"
    qm shutdown "$win" --timeout 120 || qm stop "$win"
  fi
  if [ "$which" != windows ] && ct_running "$ct"; then
    info "shutting down ubuntu CT $ct"
    pct shutdown "$ct" --timeout 120 || pct stop "$ct"
  fi
  write_owner none
  info "stopped. Host stays in $(host_mode) mode — nothing else started."
}

cmd_switch() { # $1 target  [$2 --via-reboot]
  local target=${1:-} via=0
  [ "${2:-}" = "--via-reboot" ] && via=1
  [ "$target" = windows ] || [ "$target" = ubuntu ] || die "switch <windows|ubuntu> [--via-reboot]"
  take_lock
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  vm_running "$win" && die "windows VM is running — stop it before switching"
  ct_running "$ct" && die "ubuntu CT is running — stop it before switching"
  do_switch "$target" "$via"
}

cmd_start() { # $1 target  [$2 --force|--via-reboot]
  local target=${1:-} force=0 via=0
  case "${2:-}" in
    --force)      force=1 ;;
    --via-reboot) via=1 ;;
    "") ;;
    *) die "start <windows|ubuntu> [--force|--via-reboot]" ;;
  esac
  [ "$target" = windows ] || [ "$target" = ubuntu ] || die "start <windows|ubuntu> [--force|--via-reboot]"

  take_lock
  local win ct; win=$(win_vmid); ct=$(ct_vmid)

  # 1. already running?
  if { [ "$target" = windows ] && vm_running "$win"; } || \
     { [ "$target" = ubuntu ]  && ct_running "$ct"; }; then
    info "$target already running"; write_owner "$target"; return 0
  fi

  # 2. the other guest must not be running
  local other=""
  if [ "$target" = windows ] && ct_running "$ct"; then other=ubuntu; fi
  if [ "$target" = ubuntu ]  && vm_running "$win"; then other=windows; fi
  if [ -n "$other" ]; then
    if [ "$force" = 1 ]; then
      info "--force: stopping $other first"
      if [ "$other" = windows ]; then
        qm shutdown "$win" --timeout 120 || qm stop "$win"
      else
        pct shutdown "$ct" --timeout 120 || pct stop "$ct"
      fi
    else
      die "$other is running. Stop it first:  $0 stop $other   (or pass --force)"
    fi
  fi

  # 3+4. driver ownership check + swap if needed
  do_switch "$target" "$via" || die "cannot give the hardware to $target"

  # 5. start
  if [ "$target" = windows ]; then
    [ -n "$win" ] || die "no VM named '$WIN_NAME' — run terraform -chdir=env/windows apply"
    info "qm start $win"; qm start "$win"
  else
    [ -n "$ct" ] || die "no CT named '$CT_NAME' — run terraform -chdir=env/ubuntu apply"
    info "pct start $ct"; pct start "$ct"
  fi
  write_owner "$target"
  info "$target is up (host mode: $(host_mode))"
}

cmd_resume() { # called by workstation-resume.service after a --via-reboot
  [ -f "$PENDING_FILE" ] || { info "no pending switch"; exit 0; }
  local t; t=$(cat "$PENDING_FILE"); rm -f "$PENDING_FILE"
  info "resuming pending start: $t"
  exec "$0" start "$t"
}

# ---- dispatch -----------------------------------------------------------
need_root
case "${1:-}" in
  status)  cmd_status ;;
  start)   shift; cmd_start  "$@" ;;
  stop)    shift; cmd_stop   "$@" ;;
  switch)  shift; cmd_switch "$@" ;;
  resume)  cmd_resume ;;
  *) cat >&2 <<EOF
usage: $0 <command>

  status                         show host mode, guests, PCI driver bindings
  start  <windows|ubuntu> [--force|--via-reboot]
                                 lock, refuse if the other guest is up, swap
                                 the GPU/USB bindings if needed, start the guest
  stop   [windows|ubuntu]        shut the guest(s) down; start nothing
  switch <windows|ubuntu> [--via-reboot]
                                 swap bindings only (both guests must be stopped)
  resume                         finish a --via-reboot switch (systemd unit)
EOF
     exit 1 ;;
esac
