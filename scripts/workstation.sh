#!/bin/bash
set -uo pipefail

# ============================================================
# workstation.sh — CLI for the two mutually-exclusive workstation VMs
# ============================================================
#
#   windows -> env/windows VM      ubuntu -> env/ubuntu VM
#
# Both pass the same GPU + USB controllers through vfio-pci. The interlock
# ("one at a time") is scripts/gpu-arbiter.sh, wired as a Proxmox pre-start
# hookscript on both VMs — so `qm start` / the web-UI Start button already
# refuse to start one while the other runs. This wrapper adds:
#
#   status                       -> gpu-arbiter.sh status
#   start <g> [--force]          --force = shut the OTHER guest down first
#   start <g> [--via-reboot]     rare: reboot to clear a stuck vfio bind, resume after
#   stop  [g]                    shut guest(s) down, start nothing
#
# Both VMs have on_boot=false — nothing autostarts. Run as root on the node.

WS_NAMES=(windows ubuntu)
declare -A VMNAME=([windows]=windows-workstation [ubuntu]=ubuntu-workstation)
STATE_DIR=/var/lib/workstation
LOCK_FILE=/run/lock/gpu-arbiter.lock
PENDING_FILE="$STATE_DIR/pending-start"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "[workstation] $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root on the Proxmox node"; }

ARBITER="${GPU_ARBITER:-}"
if [ -z "$ARBITER" ]; then
  for c in "$(dirname "$0")/gpu-arbiter.sh" /var/lib/vz/snippets/gpu-arbiter.sh /usr/local/sbin/gpu-arbiter.sh; do
    [ -x "$c" ] && { ARBITER="$c"; break; }
  done
fi
[ -n "$ARBITER" ] || die "gpu-arbiter.sh not found — run scripts/install-gpu-arbiter.sh"

take_lock() { exec 9>"$LOCK_FILE"; flock -w 300 9 || die "another operation is in progress"; }
drop_lock() { exec 9>&- 2>/dev/null || true; }   # release before qm start — the hook re-locks

vmid_of()    { grep -sl "^name: ${1}\$" /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
vm_running() { [ -n "${1:-}" ] && qm status "$1" 2>/dev/null | grep -q running; }
other()      { [ "$1" = windows ] && echo ubuntu || echo windows; }

stop_guest() { # $1 = windows|ubuntu
  local id; id=$(vmid_of "${VMNAME[$1]}")
  vm_running "$id" || return 0
  info "shutting down $1 ($id)"
  qm shutdown "$id" --timeout 150 || qm stop "$id"
}

cmd_start() {
  local t=${1:-} force=0 via=0
  case "${2:-}" in --force) force=1 ;; --via-reboot) via=1 ;; "") ;; *) die "start <windows|ubuntu> [--force|--via-reboot]" ;; esac
  [ "$t" = windows ] || [ "$t" = ubuntu ] || die "start <windows|ubuntu> [--force|--via-reboot]"

  take_lock
  local id oid o; id=$(vmid_of "${VMNAME[$t]}"); o=$(other "$t"); oid=$(vmid_of "${VMNAME[$o]}")
  vm_running "$id" && { info "$t already running"; return 0; }

  if vm_running "$oid"; then
    [ "$force" = 1 ] || die "$o is running. Stop it first:  $0 stop $o   (or --force)"
    info "--force: stopping $o first"; stop_guest "$o"
  fi

  if [ "$via" = 1 ]; then
    mkdir -p "$STATE_DIR"; echo "$t" >"$PENDING_FILE"
    info "rebooting the node; workstation-resume.service starts $t after boot"
    drop_lock; systemctl reboot; exit 0
  fi

  _GPU_ARBITER_LOCKED=1 "$ARBITER" ensure-vfio || die "GPU/USB not on vfio-pci (try: $0 start $t --via-reboot)"
  [ -n "$id" ] || die "no VM named '${VMNAME[$t]}' — terraform -chdir=env/$t apply"

  drop_lock                                     # the pre-start hook takes this same lock
  info "qm start $id"; qm start "$id"
  info "$t is up"
}

cmd_stop() {
  local which=${1:-both}
  case "$which" in windows|ubuntu|both) ;; *) die "stop [windows|ubuntu]" ;; esac
  take_lock
  [ "$which" != ubuntu ]  && stop_guest windows
  [ "$which" != windows ] && stop_guest ubuntu
  info "stopped — nothing else started."
}

cmd_resume() {
  [ -f "$PENDING_FILE" ] || { info "no pending start"; exit 0; }
  local t; t=$(cat "$PENDING_FILE"); rm -f "$PENDING_FILE"
  info "resuming pending start: $t"
  exec "$0" start "$t"
}

need_root
case "${1:-}" in
  status)  "$ARBITER" status ;;
  start)   shift; cmd_start "$@" ;;
  stop)    shift; cmd_stop  "$@" ;;
  resume)  cmd_resume ;;
  *) cat >&2 <<EOF
usage: $0 <command>
  status                        host mode, both VMs, PCI driver bindings
  start  <windows|ubuntu> [--force|--via-reboot]
  stop   [windows|ubuntu]       shut guest(s) down; start nothing
  resume                        finish a --via-reboot start (systemd unit)

The interlock also runs on \`qm start\` / web-UI Start via the gpu-arbiter hookscript.
EOF
     exit 1 ;;
esac
