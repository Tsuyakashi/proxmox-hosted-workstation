#!/bin/bash
#
# LVM-thin storage "hdd" on a whole spare disk of the node (bare-pve: the
# WD Red 1 TB). Holds the HDD half of the shared game disks.
#
#   ssh bare-pve 'DISK=/dev/disk/by-id/ata-WDC_WD10EFRX-68FYTN0_<serial> bash -s' < scripts/hdd-storage-init.sh
#
# Destroys whatever is on DISK. Refuses to touch a disk that has any
# partition table / filesystem / LVM signature unless FORCE=1.
# Idempotent once the storage exists.

set -euo pipefail

DISK="${DISK:?set DISK to the whole disk, preferably /dev/disk/by-id/...}"
VG="${VG:-hdd}"
POOL="${POOL:-data}"
STORAGE="${STORAGE:-hdd}"
NODE="$(hostname -s)"

if pvesm status --storage "$STORAGE" >/dev/null 2>&1; then
  echo "storage $STORAGE already exists:"; pvesm status --storage "$STORAGE"; exit 0
fi

dev=$(readlink -f "$DISK")
[ -b "$dev" ] || { echo "$DISK is not a block device"; exit 1; }
[ "$(lsblk -dno TYPE "$dev")" = disk ] || { echo "$dev is not a whole disk"; exit 1; }
if findmnt -rn -S "$dev" >/dev/null || lsblk -nro MOUNTPOINTS "$dev" | grep -q .; then
  echo "$dev (or a partition) is mounted"; exit 1
fi
if [ -n "$(wipefs -n "$dev")" ] || [ "$(lsblk -nro NAME "$dev" | wc -l)" -gt 1 ]; then
  [ "${FORCE:-0}" = 1 ] || { echo "$dev has signatures/partitions:"; wipefs -n "$dev"; lsblk "$dev"; echo "re-run with FORCE=1 to wipe"; exit 1; }
  wipefs -a "$dev"
fi

echo "creating VG $VG + thin pool $POOL on $dev ($(lsblk -dno SIZE,MODEL "$dev"))"
pvcreate -y "$dev"
vgcreate "$VG" "$dev"
# 100%FREE minus room for the pool metadata growth that lvcreate reserves.
lvcreate -y --type thin-pool -l 95%FREE -n "$POOL" "$VG"
pvesm add lvmthin "$STORAGE" --vgname "$VG" --thinpool "$POOL" \
  --content images,rootdir --nodes "$NODE"
pvesm status --storage "$STORAGE"
