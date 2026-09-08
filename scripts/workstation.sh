#!/bin/bash
set -uo pipefail

# ============================================================
# workstation.sh — human CLI on top of the GPU arbiter
# ============================================================
#
# The switch + lock ENGINE lives in scripts/gpu-arbiter.sh (also wired as a
# Proxmox hookscript on both guests, so `qm start` / `pct start` / the web-UI
# Start button already do the right thing on their own).
#
# This wrapper adds the conveniences a hookscript can't:
#   status                       -> gpu-arbiter.sh status
#   start <g> [--force]          force = shut the OTHER guest down first
#   start <g> --via-reboot       stage the switch + reboot, resume after boot
#   stop  [g]                    shut guest(s) down, start nothing
#   switch <g> [--via-reboot]    swap drivers only
#
# Both guests default OFF (on_boot=false / start_on_boot=false). Stopping one
# never starts the other. Run as root on the Proxmox host.

WIN_NAME="${WIN_NAME:-windows-workstation}"
CT_NAME="${CT_NAME:-ubuntu-workstation}"
STATE_DIR=/var/lib/workstation
LOCK_FILE=/run/lock/gpu-arbiter.lock
PENDING_FILE="$STATE_DIR/pending-start"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "[workstation] $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "must run as root (on the Proxmox host)"; }

# Locate the arbiter (checkout, snippets dir, or sbin).
ARBITER="${GPU_ARBITER:-}"
if [ -z "$ARBITER" ]; then
  for c in "$(dirname "$0")/gpu-arbiter.sh" /var/lib/vz/snippets/gpu-arbiter.sh /usr/local/sbin/gpu-arbiter.sh; do
    [ -x "$c" ] && { ARBITER="$c"; break; }
  done
fi
[ -n "$ARBITER" ] || die "gpu-arbiter.sh not found — run scripts/install-gpu-arbiter.sh on the node"

take_lock() { exec 9>"$LOCK_FILE"; flock -w 300 9 || die "another workstation.sh / gpu-arbiter operation is in progress"; }

win_vmid() { grep -sl "^name: ${WIN_NAME}\$"    /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
ct_vmid()  { grep -sl "^hostname: ${CT_NAME}\$" /etc/pve/lxc/*.conf         2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
vm_running() { [ -n "${1:-}" ] && qm  status "$1" 2>/dev/null | grep -q running; }
ct_running() { [ -n "${1:-}" ] && pct status "$1" 2>/dev/null | grep -q running; }
host_mode() { _GPU_ARBITER_LOCKED=1 "$ARBITER" status 2>/dev/null | awk '/^host mode/ {print $4; exit}'; }

stop_guest() { # $1 = windows|ubuntu
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  if [ "$1" = windows ] && vm_running "$win"; then
    info "shutting down windows VM $win"; qm shutdown "$win" --timeout 120 || qm stop "$win"
  elif [ "$1" = ubuntu ] && ct_running "$ct"; then
    info "shutting down ubuntu CT $ct"; pct shutdown "$ct" --timeout 120 || pct stop "$ct"
  fi
}

do_switch() { # $1 target  $2 via_reboot(0/1) — delegates the rebind to the arbiter
  local target=$1 via=${2:-0}
  if [ "$via" = 1 ]; then
    mkdir -p "$STATE_DIR"; echo "$target" >"$PENDING_FILE"
    info "staged switch to $target; rebooting (workstation-resume.service finishes it)"
    systemctl reboot; exit 0
  fi
  _GPU_ARBITER_LOCKED=1 "$ARBITER" switch "$target"
}

cmd_start() { # $1 target  [$2 --force|--via-reboot]
  local target=${1:-} force=0 via=0
  case "${2:-}" in
    --force) force=1 ;; --via-reboot) via=1 ;; "") ;;
    *) die "start <windows|ubuntu> [--force|--via-reboot]" ;;
  esac
  [ "$target" = windows ] || [ "$target" = ubuntu ] || die "start <windows|ubuntu> [--force|--via-reboot]"

  take_lock
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  local other; [ "$target" = windows ] && other=ubuntu || other=windows

  if { [ "$target" = windows ] && vm_running "$win"; } || { [ "$target" = ubuntu ] && ct_running "$ct"; }; then
    info "$target already running"; return 0
  fi

  if { [ "$other" = windows ] && vm_running "$win"; } || { [ "$other" = ubuntu ] && ct_running "$ct"; }; then
    [ "$force" = 1 ] || die "$other is running. Stop it first:  $0 stop $other   (or pass --force)"
    info "--force: stopping $other first"; stop_guest "$other"
  fi

  do_switch "$target" "$via" || die "cannot give the hardware to $target (try: $0 switch $target --via-reboot)"

  if [ "$target" = windows ]; then
    [ -n "$win" ] || die "no VM named '$WIN_NAME'"
    info "qm start $win"; qm start "$win"
  else
    [ -n "$ct" ] || die "no CT named '$CT_NAME' — run terraform -chdir=env/ubuntu apply"
    info "pct start $ct"; pct start "$ct"
  fi
  info "$target is up (host mode: $(host_mode))"
}

cmd_stop() {
  local which=${1:-both}
  case "$which" in windows|ubuntu|both) ;; *) die "stop [windows|ubuntu]" ;; esac
  take_lock
  [ "$which" != ubuntu ]  && stop_guest windows
  [ "$which" != windows ] && stop_guest ubuntu
  info "stopped. Host stays in $(host_mode) mode — nothing else started."
}

cmd_switch() { # $1 target  [$2 --via-reboot]
  local target=${1:-} via=0
  [ "${2:-}" = "--via-reboot" ] && via=1
  [ "$target" = windows ] || [ "$target" = ubuntu ] || die "switch <windows|ubuntu> [--via-reboot]"
  take_lock
  do_switch "$target" "$via"
}

cmd_resume() { # workstation-resume.service, after a --via-reboot
  [ -f "$PENDING_FILE" ] || { info "no pending switch"; exit 0; }
  local t; t=$(cat "$PENDING_FILE"); rm -f "$PENDING_FILE"
  info "resuming pending start: $t"
  exec "$0" start "$t"
}

need_root
case "${1:-}" in
  status)  _GPU_ARBITER_LOCKED=1 "$ARBITER" status ;;
  start)   shift; cmd_start  "$@" ;;
  stop)    shift; cmd_stop   "$@" ;;
  switch)  shift; cmd_switch "$@" ;;
  resume)  cmd_resume ;;
  *) cat >&2 <<EOF
usage: $0 <command>

  status                         host mode, guests, PCI driver bindings
  start  <windows|ubuntu> [--force|--via-reboot]
  stop   [windows|ubuntu]        shut guest(s) down; start nothing
  switch <windows|ubuntu> [--via-reboot]   swap drivers only (guests must be off)
  resume                         finish a --via-reboot switch (systemd unit)

The switch also happens automatically on \`qm start\` / \`pct start\` / web-UI Start
via the gpu-arbiter.sh hookscript.
EOF
     exit 1 ;;
esac
