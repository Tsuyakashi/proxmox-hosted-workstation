#!/bin/bash
set -uo pipefail

# ============================================================
# gpu-arbiter.sh — Proxmox guest hookscript + GPU/USB driver-swap engine
# ============================================================
#
# A workstation node has ONE discrete GPU + a set of USB controllers, shared
# by up to THREE MUTUALLY-EXCLUSIVE guests:
#
#   windows -> PCI-passthrough VM   GPU + USB functions on vfio-pci
#   macos   -> PCI-passthrough VM   GPU + USB functions on vfio-pci (same mode
#                                   as windows -- both are vfio guests; host_mode()
#                                   can't tell them apart from the PCI driver
#                                   alone, only cmd_status()'s display does, by
#                                   also checking which one is actually running)
#   ubuntu  -> LXC container        GPU on nvidia, USB on native drivers
#                                   (/dev subtrees shared into the CT)
#
# Per-node addresses (GPU_VGA / GPU_AUD / USB_FUNCS / guest names) come from
# /etc/default/gpu-arbiter (repo: host/<node>/gpu-arbiter.conf). Built-in
# defaults below are bare-pve's (Intel 8-series).
#
# This script is the single implementation of the switch + the "one OS at a
# time" lock. It is used two ways:
#
#   1. As a Proxmox hookscript on the guests (native mechanism):
#        qm  set <winid> --hookscript local:snippets/gpu-arbiter.sh
#        qm  set <macid> --hookscript local:snippets/gpu-arbiter.sh
#        pct set <ctid>  --hookscript local:snippets/gpu-arbiter.sh
#      Proxmox calls it as `<vmid> <phase>`. On `pre-start` it takes a lock,
#      refuses (exit 1 -> Proxmox ABORTS the start) if another guest is
#      running, and live-rebinds the GPU/USB to this guest's mode if needed.
#      Any start path — `qm start`, `pct start`, the web-UI Start button, the
#      API, a routine — triggers it. Other phases are no-ops (stopping one
#      guest never starts another; all-off is a valid resting state). A qemu
#      VM's identity (windows vs macos) is resolved by matching its `name:`
#      against WIN_NAME/MACOS_NAME (see vm_role()), not just "it's a VM" --
#      an unrecognized VM name is ignored (returns 0, normal Proxmox start),
#      never guessed at.
#
#      On the Ubuntu CT it also mounts the shared game disks on the host
#      (pre-start) and unmounts them (post-stop); a Windows start refuses to
#      go ahead while they are still mounted. See "shared game disks" below.
#
#   2. As a CLI (also used by scripts/workstation.sh):
#        gpu-arbiter.sh switch windows|macos|ubuntu   # rebind only, all guests off
#        gpu-arbiter.sh status                        # host mode, guests, PCI drivers
#
# Runs as root on the Proxmox host. Logs to /var/log/gpu-arbiter.log.

# ---- per-node overrides ----------------------------------------------------
# Hookscripts run without the caller's env, so node-specific addresses live in
# a file, not in env vars. See host/<node>/gpu-arbiter.conf in the repo.
ARBITER_CONF="${ARBITER_CONF:-/etc/default/gpu-arbiter}"
# shellcheck disable=SC1090
[ -r "$ARBITER_CONF" ] && . "$ARBITER_CONF"

# ---- site config (defaults = bare-pve) -------------------------------------
WIN_NAME="${WIN_NAME:-windows-workstation}"
MACOS_NAME="${MACOS_NAME:-macos-workstation}"
CT_NAME="${CT_NAME:-ubuntu-workstation}"

GPU_VGA="${GPU_VGA:-0000:01:00.0}"
GPU_AUD="${GPU_AUD:-0000:01:00.1}"
# Further functions of the same card (Turing: 01:00.2 USB-C xHCI, 01:00.3
# UCSI). They sit in the GPU's IOMMU group, so they move with it; any class.
read -r -a GPU_EXTRA <<<"${GPU_EXTRA:-}"
read -r -a USB_FUNCS <<<"${USB_FUNCS:-0000:00:14.0 0000:00:1d.0 0000:00:1a.0 0000:00:1b.0}"
NVIDIA_NODES=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset /dev/dri/card0 /dev/dri/renderD128)

# Shared game disks: the Windows VM's data disks, NTFS, used by the Ubuntu CT
# whenever Windows is off. SHARED_DISK_SLOTS are disk slots in the Windows
# VM's config; the arbiter mounts every NTFS partition on them whose label is
# in SHARED_LABELS at $SHARED_MNT_ROOT/<label> (ntfs3), and the CT gets those
# directories as bind mounts (lxc-ct-passthrough.sh).
read -r -a SHARED_DISK_SLOTS <<<"${SHARED_DISK_SLOTS:-}"
read -r -a SHARED_LABELS <<<"${SHARED_LABELS:-}"
SHARED_MNT_ROOT="${SHARED_MNT_ROOT:-/mnt/shared}"
SHARED_UID="${SHARED_UID:-1000}"
SHARED_GID="${SHARED_GID:-1000}"

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
win_vmid()   { grep -sl "^name: ${WIN_NAME}\$"    /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
macos_vmid() { grep -sl "^name: ${MACOS_NAME}\$"  /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }
ct_vmid()    { grep -sl "^hostname: ${CT_NAME}\$" /etc/pve/lxc/*.conf         2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//'; }

vm_running() { [ -n "${1:-}" ] && qm  status "$1" 2>/dev/null | grep -q running; }
ct_running() { [ -n "${1:-}" ] && pct status "$1" 2>/dev/null | grep -q running; }

vm_role() { # $1 = a qemu-server vmid -> windows|macos|unknown, by name match
  local vmid=$1
  [ "$vmid" = "$(win_vmid)" ]   && { echo windows; return; }
  [ "$vmid" = "$(macos_vmid)" ] && { echo macos; return; }
  echo unknown
}

other_guest_running() { # $1 = me (windows|macos|ubuntu). Prints "<name> <id>"
  local me=$1 win ct mac                        # and returns 0 if some OTHER
  win=$(win_vmid); ct=$(ct_vmid); mac=$(macos_vmid)  # guest is running.
  if [ "$me" != windows ] && vm_running "$win"; then echo "windows $win"; return 0; fi
  if [ "$me" != macos ]   && vm_running "$mac"; then echo "macos $mac";   return 0; fi
  if [ "$me" != ubuntu ]  && ct_running "$ct";  then echo "ubuntu $ct";   return 0; fi
  return 1
}

cur_driver() { # $1 = 0000:BB:DD.F
  local l="/sys/bus/pci/devices/$1/driver"
  if [ -L "$l" ]; then basename "$(readlink -f "$l")"; else echo "(none)"; fi
}

# Only USB (0x0c03xx) / audio (0x0403xx) functions may go to vfio via USB_FUNCS.
# Guards against a wrong-node address list (00:14.0 is xHCI on Intel 8-series,
# but SMBus on AMD FCH).
_passable() {
  case "$(cat "/sys/bus/pci/devices/$1/class" 2>/dev/null)" in
    0x0c03*|0x0403*) return 0 ;;
  esac
  return 1
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
  bind_to "$GPU_VGA" vfio-pci || rc=1
  bind_to "$GPU_AUD" vfio-pci || rc=1
  for d in "${GPU_EXTRA[@]}"; do
    bind_to "$d" vfio-pci || rc=1
  done
  for d in "${USB_FUNCS[@]}"; do
    if ! _passable "$d"; then
      log "  $d: class $(cat "/sys/bus/pci/devices/$d/class" 2>/dev/null || echo missing) is not USB/audio — skipped, fix USB_FUNCS"
      rc=1; continue
    fi
    bind_to "$d" vfio-pci || rc=1
  done
  [ "$(cur_driver "$GPU_VGA")" = vfio-pci ] || rc=1
  return $rc
}

switch_to_macos() {
  # Identical PCI targets/driver to switch_to_windows -- macOS (OpenCore,
  # vfio-pci passthrough) shares the exact same host-side vfio binding as
  # the Windows VM. Kept as its own named function (not a bare alias) so
  # do_switch()'s dispatch stays one symmetrical case per guest.
  switch_to_windows
}

switch_to_ubuntu() {
  log "binding GPU to nvidia, HDMI-audio + USB to native drivers"
  local d rc=0
  # 1. FREE the functions from vfio-pci FIRST. `modprobe nvidia` fails with
  #    "No such device" while vfio-pci still holds the only NVIDIA GPU, and
  #    then the rebind leaves it unbound. Clear override, forget the id, unbind.
  for d in "$GPU_VGA" "$GPU_AUD" "${GPU_EXTRA[@]}" "${USB_FUNCS[@]}"; do
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
  modprobe -a snd_hda_intel xhci_pci ehci_pci ohci_pci 2>/dev/null || true
  # 3. bind
  bind_to "$GPU_VGA" nvidia || rc=1
  bind_to "$GPU_AUD" ""     || rc=1                # snd_hda_intel
  for d in "${GPU_EXTRA[@]}"; do
    bind_to "$d" "" || rc=1                        # xhci_pci / ucsi_ccg
  done
  for d in "${USB_FUNCS[@]}"; do
    bind_to "$d" "" || rc=1                        # xhci/ehci/ohci_pci / snd_hda_intel
  done
  systemctl start nvidia-persistenced 2>/dev/null || true
  [ "$(cur_driver "$GPU_VGA")" = nvidia ] || { log "  GPU did not bind nvidia"; return 1; }

  # Nodes must exist before lxc binds them (the hook runs in the host ns, first).
  # Wait for the module's own registration (/proc/driver/nvidia/gpus/<BDF>/),
  # not just the PCI bind, then create the nodes deterministically.
  local gpu_proc="/proc/driver/nvidia/gpus/${GPU_VGA}" waited=0
  while [ ! -d "$gpu_proc" ] && [ "$waited" -lt 1200 ]; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -d "$gpu_proc" ]; then
    log "  nvidia never registered $GPU_VGA under /proc/driver/nvidia/gpus (waited ${waited}00ms)"
    rc=1
  else
    [ "$waited" -gt 0 ] && log "  nvidia registered $GPU_VGA after ${waited}00ms"
    # nvidia-modprobe sometimes exits 0 without mknod — try it, then fall back
    # to creating the nodes ourselves (major from /proc/devices).
    nvidia-modprobe -c0 -u -m 2>/dev/null || nvidia-modprobe -c0 -u 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true

    _char_major() { awk -v n="$1" '$2==n{print $1; exit}' /proc/devices; }
    _ensure_node() { # $1 path  $2 major  $3 minor
      [ -e "$1" ] && return 0
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { log "  can't mknod $1 (major/minor unknown)"; return 1; }
      mknod -m 666 "$1" c "$2" "$3" 2>/dev/null || { log "  mknod $1 c $2 $3 failed"; return 1; }
      log "  created $1 (c $2 $3)"
    }
    local gpu_minor uvm_major
    gpu_minor=$(sed -n 's/^Device Minor:[[:space:]]*//p' "${gpu_proc}/information" 2>/dev/null)
    uvm_major=$(_char_major nvidia-uvm)
    _ensure_node /dev/nvidia0         "$(_char_major nvidia)"          "${gpu_minor:-0}"
    _ensure_node /dev/nvidiactl       "$(_char_major nvidiactl)"       255
    _ensure_node /dev/nvidia-modeset  "$(_char_major nvidia-modeset)"  254
    _ensure_node /dev/nvidia-uvm       "$uvm_major" 0
    _ensure_node /dev/nvidia-uvm-tools "$uvm_major" 1
  fi
  local n
  for n in "${NVIDIA_NODES[@]}"; do
    [ -e "$n" ] || { log "  $n still missing"; rc=1; }
  done
  return $rc
}

do_switch() { # $1 target  — live rebind only, no guest-running guard (caller's job)
  local target=$1 from; from=$(host_mode)
  # Always run the (idempotent) rebind — even when the GPU is already on the
  # right driver the USB / audio functions may not be.
  [ "$from" = "$target" ] && log "host GPU already $target — verifying USB/audio" \
                          || log "swapping host $from -> $target (live PCI rebind)"
  local rc=0
  case "$target" in
    windows) switch_to_windows || rc=$? ;;
    macos)   switch_to_macos   || rc=$? ;;
    ubuntu)  switch_to_ubuntu  || rc=$? ;;
  esac
  if [ "$rc" -ne 0 ]; then
    log "live rebind to $target FAILED — a device is still held (guest not fully stopped,"
    log "nvidia-persistenced, or an Xorg on the host) or USB_FUNCS is wrong. Recover with:"
    log "    scripts/workstation.sh switch $target --via-reboot"
    return 1
  fi
  log "host now in $target mode"
}

# ---- shared game disks ---------------------------------------------------
# Host block devices of the Windows VM's shared slots, one per line.
_shared_devs() {
  local win slot vol
  win=$(win_vmid); [ -n "$win" ] || return 0
  for slot in "${SHARED_DISK_SLOTS[@]}"; do
    vol=$(qm config "$win" 2>/dev/null | sed -n "s/^${slot}: \([^,]*\).*/\1/p")
    [ -n "$vol" ] || { log "  shared: $slot not in VM $win config, skipped"; continue; }
    pvesm path "$vol" 2>/dev/null || log "  shared: no host path for $vol"
  done
}

_shared_known_label() { local l; for l in "${SHARED_LABELS[@]}"; do [ "$l" = "$1" ] && return 0; done; return 1; }

# Mount every labelled NTFS partition for the CT. Never fatal: a missing or
# hibernated (Windows Fast Startup) volume only means the CT starts without
# it — the bind-mount target stays an immutable empty dir, so nothing can be
# written to the host rootfs by mistake.
shared_mount() {
  [ "${#SHARED_DISK_SLOTS[@]}" -gt 0 ] || return 0
  local dev dm part label mnt
  while read -r dev; do
    [ -n "$dev" ] || continue
    lvchange -ay "$dev" >/dev/null 2>&1 || true
    kpartx -as "$dev" >/dev/null 2>&1 || { log "  shared: kpartx failed on $dev"; continue; }
    dm=$(dmsetup info -c --noheadings -o name "$dev" 2>/dev/null) || continue
    for part in /dev/mapper/"${dm}"p*; do
      [ -b "$part" ] || continue
      [ "$(blkid -o value -s TYPE "$part" 2>/dev/null)" = ntfs ] || continue
      label=$(blkid -o value -s LABEL "$part" 2>/dev/null)
      _shared_known_label "$label" || continue
      mnt="$SHARED_MNT_ROOT/$label"
      mountpoint -q "$mnt" && { log "  shared: $mnt already mounted"; continue; }
      install -d "$mnt"
      if mount -t ntfs3 -o "uid=$SHARED_UID,gid=$SHARED_GID,windows_names,prealloc,noatime" "$part" "$mnt" 2>>"$LOG_FILE"; then
        log "  shared: $part ($label) -> $mnt"
      else
        log "  shared: mount of $part ($label) FAILED — hibernated by Windows Fast Startup? (powercfg /h off in Windows)"
      fi
    done
  done < <(_shared_devs)
}

# Unmount everything under SHARED_MNT_ROOT and drop the partition maps.
# Returns 1 if something is still mounted: Windows must not start then.
shared_umount() {
  [ "${#SHARED_DISK_SLOTS[@]}" -gt 0 ] || return 0
  local mnt dev rc=0
  for mnt in $(findmnt -rn -o TARGET | grep "^${SHARED_MNT_ROOT}/" || true); do
    if umount "$mnt" 2>>"$LOG_FILE"; then log "  shared: unmounted $mnt"
    else log "  shared: $mnt is BUSY ($(fuser -vm "$mnt" 2>&1 | tail -n +2 | awk '{print $NF}' | sort -u | tr '\n' ' '))"; rc=1
    fi
  done
  [ "$rc" -eq 0 ] || return 1
  while read -r dev; do
    [ -n "$dev" ] && kpartx -ds "$dev" >/dev/null 2>&1 || true
  done < <(_shared_devs)
}

# ---- Proxmox hook: pre-start ------------------------------------------
hook_prestart() { # $1 = vmid
  local vmid=$1 me target
  if [ -f "/etc/pve/qemu-server/${vmid}.conf" ]; then
    me=$(vm_role "$vmid")
    if [ "$me" = unknown ]; then
      log "pre-start for $vmid: qemu VM name matches neither WIN_NAME ($WIN_NAME)"
      log "  nor MACOS_NAME ($MACOS_NAME), ignoring (not an arbiter-managed guest)"
      return 0
    fi
  elif [ -f "/etc/pve/lxc/${vmid}.conf" ]; then
    me=ubuntu
  else
    log "pre-start for $vmid: not a known guest type, ignoring"; return 0
  fi
  target=$me

  take_lock
  log "pre-start: vmid=$vmid ($me), host currently in $(host_mode) mode"

  local info
  if info=$(other_guest_running "$me"); then
    local other=${info%% *} other_id=${info##* }
    log "REFUSING to start $vmid: the $other guest ($other_id) is running."
    log "Stop it first:  scripts/workstation.sh stop $other   (or: start $me --force)"
    exit 1
  fi

  if [ "$me" = windows ] && ! shared_umount; then
    log "REFUSING to start $vmid: shared game disks still mounted on the host."
    exit 1
  fi
  do_switch "$target" || exit 1
  [ "$me" = ubuntu ] && shared_mount
  log "pre-start: ok, $me may start"
}

# ---- Proxmox hook: post-stop (CT only) --------------------------------
# Releases the shared game disks once the CT is down. Not a chain: nothing
# else is started.
#
# NO LOCK here. workstation.sh holds the lock while it stops the CT, and
# lxc-stop does not return until this hook has finished: waiting for the
# lock would deadlock both (the CT hangs as "running" without a PID). No
# lock is needed either: the CT is down, and its next pre-start cannot run
# before this hook returns; a Windows pre-start unmounts again under the lock.
hook_poststop() { # $1 = vmid
  [ -f "/etc/pve/lxc/${1}.conf" ] || return 0
  log "post-stop: vmid=$1 (ubuntu), releasing shared game disks"
  shared_umount || log "post-stop: shared disks still mounted — the next Windows start will refuse"
}

# ---- CLI: status -----------------------------------------------------
cmd_status() {
  local win ct mac; win=$(win_vmid); ct=$(ct_vmid); mac=$(macos_vmid)
  local mode; mode=$(host_mode)
  # host_mode() can't tell macOS from Windows (both vfio) — disambiguate display only.
  [ "$mode" = windows ] && vm_running "$mac" && mode=macos
  echo "config         : $([ -r "$ARBITER_CONF" ] && echo "$ARBITER_CONF" || echo "built-in defaults (bare-pve)")"
  echo "host mode      : $mode   (GPU $GPU_VGA driver: $(cur_driver "$GPU_VGA"))"
  echo "windows VM     : id=${win:-not-created}  $(vm_running "$win" && echo RUNNING || echo stopped)"
  echo "macos   VM     : id=${mac:-not-created}  $(vm_running "$mac" && echo RUNNING || echo stopped)"
  echo "ubuntu  CT     : id=${ct:-not-created}  $(ct_running "$ct" && echo RUNNING || echo stopped)"
  echo
  echo "PCI function -> driver:"
  local d
  for d in "$GPU_VGA" "$GPU_AUD" "${GPU_EXTRA[@]}" "${USB_FUNCS[@]}"; do
    printf '  %s  %s\n' "$d" "$(cur_driver "$d")"
  done
  if [ "${#SHARED_DISK_SLOTS[@]}" -gt 0 ]; then
    echo
    echo "shared game disks (${SHARED_DISK_SLOTS[*]} of the windows VM):"
    _shared_devs | sed 's/^/  /'
    findmnt -rn -o TARGET,SOURCE,FSTYPE | grep "^${SHARED_MNT_ROOT}/" | sed 's/^/  mounted: /' || echo "  (not mounted)"
  fi
}

# ---- CLI: switch ---------------------------------------------------
cmd_switch() { # $1 = windows|macos|ubuntu
  local target=${1:-}
  case "$target" in windows|macos|ubuntu) ;; *) die "switch <windows|macos|ubuntu>" ;; esac
  take_lock
  local win ct mac; win=$(win_vmid); ct=$(ct_vmid); mac=$(macos_vmid)
  vm_running "$win" && die "windows VM is running — stop it before switching"
  vm_running "$mac" && die "macos VM is running — stop it before switching"
  ct_running "$ct"  && die "ubuntu CT is running — stop it before switching"
  do_switch "$target"
}

# ---- dispatch -----------------------------------------------------
need_root
case "${2:-}" in
  pre-start)                    hook_prestart "${1:?vmid}" ;;
  post-stop)                    hook_poststop "${1:?vmid}" ;;   # unmount only, never auto-chain
  post-start|pre-stop)          exit 0 ;;
  *)
    case "${1:-}" in
      switch) cmd_switch "${2:-}" ;;
      status) cmd_status ;;
      *) cat >&2 <<EOF
gpu-arbiter.sh — Proxmox GPU/USB arbiter

As a hookscript (attached to the guests):  gpu-arbiter.sh <vmid> <phase>
As a CLI:
  gpu-arbiter.sh switch <windows|macos|ubuntu>   rebind GPU/USB (all guests must be off)
  gpu-arbiter.sh status                          show host mode, guests, PCI drivers

Per-node config: $ARBITER_CONF
EOF
         exit 1 ;;
    esac ;;
esac

