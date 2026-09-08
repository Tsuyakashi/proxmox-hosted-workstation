#!/bin/bash
set -uo pipefail

# ============================================================
# gpu-arbiter.sh — "only one workstation guest at a time" lock
# ============================================================
#
# bare-pve has ONE discrete GPU + one set of USB controllers, passed through
# (vfio-pci) to two MUTUALLY-EXCLUSIVE VMs:
#
#   windows-workstation   env/windows
#   ubuntu-workstation    env/ubuntu
#
# Both want the same devices on vfio-pci, so there is NO driver swap — the
# host stays in vfio-pci mode (scripts/iommu-vfio-setup.sh). This script is
# just the interlock.
#
# Used two ways:
#
#   1. Proxmox hookscript on BOTH VMs (native):
#        qm set <winid>    --hookscript local:snippets/gpu-arbiter.sh
#        qm set <ubuntuid> --hookscript local:snippets/gpu-arbiter.sh
#      On `pre-start` it takes a lock and, if the OTHER workstation VM is
#      running, exits non-zero -> Proxmox ABORTS the start. It also makes sure
#      the GPU/USB functions are actually on vfio-pci (belt-and-braces, e.g.
#      after the host was in some other state).
#      post-* phases are no-ops: stopping one guest never starts the other.
#
#   2. CLI (also used by scripts/workstation.sh):
#        gpu-arbiter.sh ensure-vfio   # rebind GPU/USB to vfio-pci, no guest may run
#        gpu-arbiter.sh status
#
# Runs as root on the node. Logs to /var/log/gpu-arbiter.log.
# Override discovery via env: WS_NAMES, GPU_FUNCS, USB_FUNCS.

WS_NAMES=(${WS_NAMES:-windows-workstation ubuntu-workstation})
GPU_FUNCS=(${GPU_FUNCS:-0000:01:00.0 0000:01:00.1})
USB_FUNCS=(${USB_FUNCS:-0000:00:14.0 0000:00:1d.0 0000:00:1a.0 0000:00:1b.0})

LOCK_FILE=/run/lock/gpu-arbiter.lock
LOG_FILE=/var/log/gpu-arbiter.log

log() { echo "$(date '+%F %T') [$$] $*" | tee -a "$LOG_FILE" >&2; }
die() { log "error: $*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root on the Proxmox node"; }

take_lock() {
  [ -n "${_GPU_ARBITER_LOCKED:-}" ] && return 0
  exec 9>"$LOCK_FILE"
  flock -w 300 9 || die "another gpu-arbiter / workstation.sh operation is in progress"
}

vmid_of() { grep -sl "^name: ${1}\$" /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
vm_running() { [ -n "${1:-}" ] && qm status "$1" 2>/dev/null | grep -q running; }
name_of_vmid() { sed -n 's/^name: //p' "/etc/pve/qemu-server/${1}.conf" 2>/dev/null; }

cur_driver() {
  local l="/sys/bus/pci/devices/$1/driver"
  if [ -L "$l" ]; then basename "$(readlink -f "$l")"; else echo "(none)"; fi
}
all_vfio() {
  local d
  for d in "${GPU_FUNCS[@]}" "${USB_FUNCS[@]}"; do
    [ "$(cur_driver "$d")" = vfio-pci ] || return 1
  done
  return 0
}

# ---- rebind GPU/USB to vfio-pci (only when nothing holds them) ----------
ensure_vfio() {
  all_vfio && { log "GPU + USB already on vfio-pci"; return 0; }
  local n
  for n in "${WS_NAMES[@]}"; do
    vm_running "$(vmid_of "$n")" && die "$n is running — cannot rebind while a guest holds the devices"
  done
  systemctl stop nvidia-persistenced 2>/dev/null || true
  modprobe vfio-pci 2>/dev/null || modprobe vfio_pci 2>/dev/null || true
  local d rc=0
  for d in "${GPU_FUNCS[@]}" "${USB_FUNCS[@]}"; do
    [ "$(cur_driver "$d")" = vfio-pci ] && continue
    printf '%s\n' vfio-pci >"/sys/bus/pci/devices/$d/driver_override" 2>/dev/null || true
    [ -L "/sys/bus/pci/devices/$d/driver" ] && echo "$d" >"/sys/bus/pci/devices/$d/driver/unbind" 2>/dev/null || true
    echo "$d" >/sys/bus/pci/drivers_probe 2>/dev/null || true
    [ "$(cur_driver "$d")" = vfio-pci ] || { log "  $d did not bind vfio-pci (now: $(cur_driver "$d"))"; rc=1; }
  done
  [ "$rc" = 0 ] && log "GPU + USB -> vfio-pci" || log "some functions failed to rebind — a reboot fixes it"
  return $rc
}

# ---- Proxmox hook: pre-start ------------------------------------------
hook_prestart() { # $1 = vmid
  local vmid=$1 me other other_id n
  me=$(name_of_vmid "$vmid")
  case " ${WS_NAMES[*]} " in *" $me "*) ;; *) log "pre-start $vmid ($me): not a workstation guest, ignoring"; return 0 ;; esac

  take_lock
  for n in "${WS_NAMES[@]}"; do [ "$n" != "$me" ] && other=$n; done
  other_id=$(vmid_of "$other")
  log "pre-start: $vmid ($me); other=$other ($other_id)"

  if vm_running "$other_id"; then
    log "REFUSING: $other ($other_id) is running. Stop it first:  workstation.sh stop $other"
    exit 1
  fi
  all_vfio || ensure_vfio || { log "hardware not ready for $me"; exit 1; }
  log "pre-start: ok, $me may start"
}

# ---- CLI ---------------------------------------------------------------
cmd_status() {
  local n id
  echo "host: GPU ${GPU_FUNCS[0]} driver = $(cur_driver "${GPU_FUNCS[0]}")   (all-vfio: $(all_vfio && echo yes || echo NO))"
  for n in "${WS_NAMES[@]}"; do
    id=$(vmid_of "$n")
    printf '%-22s id=%-6s %s\n' "$n" "${id:-not-created}" "$(vm_running "$id" && echo RUNNING || echo stopped)"
  done
  echo
  local d
  for d in "${GPU_FUNCS[@]}" "${USB_FUNCS[@]}"; do printf '  %s  %s\n' "$d" "$(cur_driver "$d")"; done
}

need_root
case "${2:-}" in
  pre-start)                     hook_prestart "${1:?vmid}" ;;
  post-start|pre-stop|post-stop) exit 0 ;;
  *)
    case "${1:-}" in
      ensure-vfio) take_lock; ensure_vfio ;;
      status)      cmd_status ;;
      *) cat >&2 <<EOF
gpu-arbiter.sh — workstation guest interlock

hookscript:  gpu-arbiter.sh <vmid> <phase>   (attach to both workstation VMs)
CLI:
  gpu-arbiter.sh status        host mode, both VMs, PCI driver bindings
  gpu-arbiter.sh ensure-vfio   rebind GPU/USB to vfio-pci (no guest may run)
EOF
         exit 1 ;;
    esac ;;
esac
