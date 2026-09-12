#!/bin/bash
set -uo pipefail

# ============================================================
# gpu-arbiter.sh — Proxmox guest hookscript + GPU/USB driver-swap engine
# ============================================================
#
# bare-pve has ONE discrete GPU + one set of USB controllers, shared by two
# MUTUALLY-EXCLUSIVE guests:
#
#   windows -> PCI-passthrough VM   GPU + USB functions on vfio-pci
#   ubuntu  -> LXC container        GPU on nvidia, USB on native drivers
#                                   (/dev subtrees shared into the CT)
#
# This script is the single implementation of the switch + the "one OS at a
# time" lock. It is used two ways:
#
#   1. As a Proxmox hookscript on BOTH guests (native mechanism):
#        qm  set <winid> --hookscript local:snippets/gpu-arbiter.sh
#        pct set <ctid>  --hookscript local:snippets/gpu-arbiter.sh
#      Proxmox calls it as `<vmid> <phase>`. On `pre-start` it takes a lock,
#      refuses (exit 1 -> Proxmox ABORTS the start) if the other guest is
#      running, and live-rebinds the GPU/USB to this guest's mode if needed.
#      Any start path — `qm start`, `pct start`, the web-UI Start button, the
#      API, a routine — triggers it. Other phases are no-ops (stopping one
#      guest never starts the other; both-off is a valid resting state).
#
#   2. As a CLI (also used by scripts/workstation.sh):
#        gpu-arbiter.sh switch windows|ubuntu   # rebind only, both guests must be off
#        gpu-arbiter.sh status                  # host mode, guests, PCI drivers
#
# Runs as root on the Proxmox host. Logs to /var/log/gpu-arbiter.log.
# Override discovery via env: WIN_NAME, CT_NAME, GPU_VGA, GPU_AUD, USB_FUNCS.

# ---- site config -----------------------------------------------------------
WIN_NAME="${WIN_NAME:-windows-workstation}"
CT_NAME="${CT_NAME:-ubuntu-workstation}"

GPU_VGA="${GPU_VGA:-0000:01:00.0}"
GPU_AUD="${GPU_AUD:-0000:01:00.1}"
read -r -a USB_FUNCS <<<"${USB_FUNCS:-0000:00:14.0 0000:00:1d.0 0000:00:1a.0 0000:00:1b.0}"
NVIDIA_MODS=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
NVIDIA_NODES=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset /dev/dri/card0 /dev/dri/renderD128)

LOCK_FILE=/run/lock/gpu-arbiter.lock
LOG_FILE=/var/log/gpu-arbiter.log

# ---- logging / lock -------------------------------------------------------
log() { echo "$(date '+%F %T') [$$] $*" | tee -a "$LOG_FILE" >&2; }
die() { log "error: $*"; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "must run as root (on the Proxmox host)"; }

take_lock() {
  [ -n "${_GPU_ARBITER_LOCKED:-}" ] && return 0   # caller (workstation.sh) holds it
  exec 9>"$LOCK_FILE"
  flock -w 300 9 || die "another gpu-arbiter / workstation.sh operation is in progress"
}

# ---- discovery ----------------------------------------------------------
win_vmid() { grep -sl "^name: ${WIN_NAME}\$"    /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
ct_vmid()  { grep -sl "^hostname: ${CT_NAME}\$" /etc/pve/lxc/*.conf         2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }

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

# ---- PCI rebind -------------------------------------------------------
_unbind() {
  local d=$1 drv; drv=$(cur_driver "$d")
  [ "$drv" = "(none)" ] && return 0
  echo "$d" >"/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null || return 1
}

_vfio_forget() { # $1 device — drop its id from vfio-pci's dynamic table so a
  local d=$1 vd dd                                   # probe won't re-grab it
  vd=$(cat "/sys/bus/pci/devices/$d/vendor" 2>/dev/null); vd=${vd#0x}
  dd=$(cat "/sys/bus/pci/devices/$d/device" 2>/dev/null); dd=${dd#0x}
  [ -n "$vd" ] && [ -n "$dd" ] && \
    echo "$vd $dd" >/sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
}

bind_to() { # $1 device, $2 target driver ("" = clear override -> kernel default match)
  local d=$1 target=${2:-} ovr="/sys/bus/pci/devices/$1/driver_override"
  # idempotent: nothing to do if already on an acceptable driver
  if [ -n "$target" ]; then
    [ "$(cur_driver "$d")" = "$target" ] && return 0
  else
    case "$(cur_driver "$d")" in vfio-pci|"(none)") ;; *) return 0 ;; esac
  fi
  if [ -n "$target" ]; then printf '%s\n' "$target" >"$ovr" 2>/dev/null || true
  else printf '\n' >"$ovr" 2>/dev/null || true; _vfio_forget "$d"
  fi
  _unbind "$d" || { log "  $d busy (held by $(cur_driver "$d")) — cannot rebind"; return 1; }
  printf '%s\n' "$d" >/sys/bus/pci/drivers_probe 2>/dev/null || true
  return 0
}

switch_to_windows() {
  log "binding GPU + HDMI-audio + USB to vfio-pci"
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
  log "binding GPU to nvidia, HDMI-audio + USB to native drivers"
  local d rc=0
  # 1. FREE the functions from vfio-pci FIRST. `modprobe nvidia` fails with
  #    "No such device" while vfio-pci still holds the only NVIDIA GPU, and
  #    then the rebind leaves it unbound. Clear override, forget the id, unbind.
  for d in "$GPU_VGA" "$GPU_AUD" "${USB_FUNCS[@]}"; do
    [ "$(cur_driver "$d")" = vfio-pci ] || continue
    printf '\n' >"/sys/bus/pci/devices/$d/driver_override" 2>/dev/null || true
    _vfio_forget "$d"
    echo "$d" >"/sys/bus/pci/devices/$d/driver/unbind" 2>/dev/null || true
  done
  # 2. now the GPU is free -> load nvidia (+ drm with modeset/fbdev for /dev/fb0)
  #    `-a`: without it modprobe treats nvidia_uvm / nvidia_modeset as kernel
  #    params to `nvidia` and silently drops them ("unknown parameter ... ignored").
  modprobe -a nvidia nvidia_uvm nvidia_modeset 2>/dev/null || true
  modprobe -r nvidia_drm 2>/dev/null || true
  modprobe nvidia_drm modeset=1 fbdev=1 2>/dev/null || modprobe nvidia_drm 2>/dev/null || true
  modprobe snd_hda_intel xhci_pci ehci_pci ehci-pci 2>/dev/null || true
  # 3. bind
  bind_to "$GPU_VGA" nvidia || rc=1
  bind_to "$GPU_AUD" ""     || rc=1                # snd_hda_intel
  for d in "${USB_FUNCS[@]}"; do
    bind_to "$d" "" || rc=1                        # xhci_pci / ehci-pci / snd_hda_intel
  done
  systemctl start nvidia-persistenced 2>/dev/null || true
  [ "$(cur_driver "$GPU_VGA")" = nvidia ] || { log "  GPU did not bind nvidia"; return 1; }

  # Nodes must exist before lxc binds them (the hook runs in the host ns, first).
  # nvidia-modprobe is what *creates* /dev/nvidia0 + /dev/nvidiactl, but it can
  # only do that once the nvidia kernel module has *internally* finished
  # registering the GPU — `Kernel driver in use: nvidia` (what cur_driver
  # checks above) only means the PCI subsystem bound the driver; the module's
  # own probe (vBIOS init, KMS/DRM registration, framebuffer takeover, and —
  # after a live unbind from vfio-pci — an actual device reset) can still be
  # running for a while after that, especially right after a host reboot.
  # Polling nvidia-modprobe's exit status and hoping (2026-09-10 PR #11: 15s
  # budget; 2026-09-12: still not always enough) is guessing at a timeout for
  # a condition we can just check directly: the module publishes
  # /proc/driver/nvidia/gpus/<BDF>/ the moment registration completes. Wait on
  # THAT (deterministic, no arbitrary budget to tune), then create the nodes
  # once — not in a hope-it-eventually-works loop.
  local gpu_proc="/proc/driver/nvidia/gpus/${GPU_VGA}" waited=0
  while [ ! -d "$gpu_proc" ] && [ "$waited" -lt 1200 ]; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -d "$gpu_proc" ]; then
    log "  nvidia never registered $GPU_VGA under /proc/driver/nvidia/gpus (waited ${waited}00ms)"
    rc=1
  else
    [ "$waited" -gt 0 ] && log "  nvidia registered $GPU_VGA after ${waited}00ms"
    local nvm_err
    nvm_err=$(nvidia-modprobe -c0 -u -m 2>&1) || nvm_err=$(nvidia-modprobe -c0 -u 2>&1) || true
    udevadm settle --timeout=10 2>/dev/null || true
  fi
  local n
  for n in "${NVIDIA_NODES[@]}"; do
    [ -e "$n" ] || { log "  $n still missing (${nvm_err:-nvidia not yet registered})"; rc=1; }
  done
  return $rc
}

do_switch() { # $1 target  — live rebind only, no guest-running guard (caller's job)
  local target=$1 from; from=$(host_mode)
  # Always run the (idempotent) rebind — even when the GPU is already on the
  # right driver the USB / audio functions may not be (e.g. after a manual
  # host bring-up).
  [ "$from" = "$target" ] && log "host GPU already $target — verifying USB/audio" \
                          || log "swapping host $from -> $target (live PCI rebind)"
  local rc=0
  if [ "$target" = windows ]; then switch_to_windows || rc=$?; else switch_to_ubuntu || rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    log "live rebind to $target FAILED — a device is still held (guest not fully stopped,"
    log "nvidia-persistenced, or an Xorg on the host). Recover with:"
    log "    scripts/workstation.sh switch $target --via-reboot"
    return 1
  fi
  log "host now in $target mode"
}

# ---- Proxmox hook: pre-start ------------------------------------------
hook_prestart() { # $1 = vmid
  local vmid=$1 me target other other_id
  if   [ -f "/etc/pve/qemu-server/${vmid}.conf" ]; then me=windows
  elif [ -f "/etc/pve/lxc/${vmid}.conf" ];         then me=ubuntu
  else log "pre-start for $vmid: not a known guest type, ignoring"; return 0
  fi
  target=$me

  take_lock
  log "pre-start: vmid=$vmid ($me), host currently in $(host_mode) mode"

  if [ "$me" = windows ]; then other=ubuntu;  other_id=$(ct_vmid)
  else                         other=windows; other_id=$(win_vmid)
  fi
  if { [ "$other" = windows ] && vm_running "$other_id"; } || \
     { [ "$other" = ubuntu ]  && ct_running "$other_id"; }; then
    log "REFUSING to start $vmid: the $other guest ($other_id) is running."
    log "Stop it first:  scripts/workstation.sh stop $other   (or: start $me --force)"
    exit 1
  fi

  do_switch "$target" || exit 1
  log "pre-start: ok, $me may start"
}

# ---- CLI: status -----------------------------------------------------
cmd_status() {
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  echo "host mode      : $(host_mode)   (GPU $GPU_VGA driver: $(cur_driver "$GPU_VGA"))"
  echo "windows VM     : id=${win:-not-created}  $(vm_running "$win" && echo RUNNING || echo stopped)"
  echo "ubuntu  CT     : id=${ct:-not-created}  $(ct_running "$ct" && echo RUNNING || echo stopped)"
  echo
  echo "PCI function -> driver:"
  local d
  for d in "$GPU_VGA" "$GPU_AUD" "${USB_FUNCS[@]}"; do
    printf '  %s  %s\n' "$d" "$(cur_driver "$d")"
  done
}

# ---- CLI: switch ---------------------------------------------------
cmd_switch() { # $1 = windows|ubuntu
  local target=${1:-}
  [ "$target" = windows ] || [ "$target" = ubuntu ] || die "switch <windows|ubuntu>"
  take_lock
  local win ct; win=$(win_vmid); ct=$(ct_vmid)
  vm_running "$win" && die "windows VM is running — stop it before switching"
  ct_running "$ct"  && die "ubuntu CT is running — stop it before switching"
  do_switch "$target"
}

# ---- dispatch -----------------------------------------------------
need_root
case "${2:-}" in
  pre-start)                    hook_prestart "${1:?vmid}" ;;
  post-start|pre-stop|post-stop) exit 0 ;;   # never auto-chain
  *)
    case "${1:-}" in
      switch) cmd_switch "${2:-}" ;;
      status) cmd_status ;;
      *) cat >&2 <<EOF
gpu-arbiter.sh — Proxmox GPU/USB arbiter

As a hookscript (attached to both guests):  gpu-arbiter.sh <vmid> <phase>
As a CLI:
  gpu-arbiter.sh switch <windows|ubuntu>   rebind GPU/USB (both guests must be off)
  gpu-arbiter.sh status                    show host mode, guests, PCI drivers
EOF
         exit 1 ;;
    esac ;;
esac
