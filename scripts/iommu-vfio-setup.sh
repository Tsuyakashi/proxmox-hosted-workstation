#!/bin/bash
set -euo pipefail

# ============================================================
# GPU / whole-workstation passthrough host setup (idempotent)
# Target: Proxmox VE host, GRUB bootloader
# ============================================================
#
# Binds to vfio-pci at boot:
#   - the discrete GPU + its HDMI-audio function (always)
#   - every USB controller that sits in an IOMMU group containing only USB
#     controllers, plus the onboard HD-audio controller if it is alone in its
#     group      -> only when WS_FULL_PASSTHROUGH=1 (default)
#
# The host is left with just storage + the NIC. Console access becomes
# SSH / IPMI only — a local USB keyboard on the host will stop working.
#
#   ssh bare-pve 'bash -s' < scripts/iommu-vfio-setup.sh              # full
#   ssh bare-pve 'WS_FULL_PASSTHROUGH=0 bash -s' < scripts/...        # GPU only

WS_FULL_PASSTHROUGH="${WS_FULL_PASSTHROUGH:-1}"

REBOOT_REQUIRED=false
CHANGES_MADE=()

# ------------------------------------------------------------
# 1. IOMMU in GRUB
# ------------------------------------------------------------
GRUB_FILE="/etc/default/grub"

if grep -q "GenuineIntel" /proc/cpuinfo; then
  IOMMU_PARAM="intel_iommu=on"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
  IOMMU_PARAM="amd_iommu=on"
else
  echo "Unknown CPU vendor, exiting"
  exit 1
fi

PT_PARAM="iommu=pt"

if grep -q "$IOMMU_PARAM" "$GRUB_FILE"; then
  echo "[grub] IOMMU already enabled, skipping"
else
  sed -i.bak -E \
    "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)(\")/\1\2 ${IOMMU_PARAM} ${PT_PARAM}\3/" \
    "$GRUB_FILE"
  echo "[grub] Added: $IOMMU_PARAM $PT_PARAM"
  update-grub
  CHANGES_MADE+=("grub cmdline")
  REBOOT_REQUIRED=true
fi

# ------------------------------------------------------------
# 2. VFIO modules in /etc/modules
# ------------------------------------------------------------
MODULES_FILE="/etc/modules"
VFIO_MODULES=("vfio" "vfio_iommu_type1" "vfio_pci")

for module in "${VFIO_MODULES[@]}"; do
  if grep -qxF "$module" "$MODULES_FILE"; then
    echo "[modules] $module already present, skipping"
  else
    echo "$module" >> "$MODULES_FILE"
    echo "[modules] Added: $module"
    CHANGES_MADE+=("module $module")
    REBOOT_REQUIRED=true
  fi
done

# ------------------------------------------------------------
# 3. Auto-detect GPU PCI address and IDs
# ------------------------------------------------------------
# Allow manual override via env var if auto-detection is ambiguous
# GPU_PCI_OVERRIDE=01:00.0 ./iommu-vfio-setup.sh

GPU_LINE=$(lspci -nn | grep -i "vga\|3d controller" | grep -iv "intel" | head -n1 || true)

if [ -z "$GPU_LINE" ]; then
  echo "[gpu-detect] No discrete GPU found automatically, exiting"
  exit 1
fi

GPU_PCI_ADDR=$(echo "$GPU_LINE" | awk '{print $1}')
GPU_BUS_SLOT=$(echo "$GPU_PCI_ADDR" | cut -d. -f1)
GPU_VGA_ID=$(echo "$GPU_LINE" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | tail -n1)

echo "[gpu-detect] Found GPU at $GPU_PCI_ADDR (ID: $GPU_VGA_ID)"

# Check for associated audio function (same bus:slot, function .1)
GPU_AUDIO_LINE=$(lspci -n -s "$GPU_BUS_SLOT" | grep "\.1 " || true)
GPU_IDS="$GPU_VGA_ID"

if [ -n "$GPU_AUDIO_LINE" ]; then
  GPU_AUDIO_ID=$(echo "$GPU_AUDIO_LINE" | awk '{print $2}')
  GPU_IDS="${GPU_VGA_ID},${GPU_AUDIO_ID}"
  echo "[gpu-detect] Found audio function: $GPU_AUDIO_ID"
else
  echo "[gpu-detect] No audio function found for this GPU"
fi

# ------------------------------------------------------------
# 3b. Extra whole-device passthrough (USB controllers + onboard audio)
# ------------------------------------------------------------
# A group is safe to hand over wholesale when every device in it is a USB
# controller (class 0c03). The onboard HD-audio controller (class 0403) is
# added when it is the only device in its group.
EXTRA_IDS=""

group_of() { basename "$(readlink -f "/sys/bus/pci/devices/0000:$1/iommu_group")"; }

if [ "$WS_FULL_PASSTHROUGH" = "1" ]; then
  declare -A SEEN_GROUP=()
  while read -r addr _; do
    [ -n "$addr" ] || continue
    grp=$(group_of "$addr") || continue
    [ -n "${SEEN_GROUP[$grp]:-}" ] && continue
    SEEN_GROUP[$grp]=1

    # class: 0x0c03xx = USB controller (UHCI/OHCI/EHCI/XHCI), 0x0403xx = audio
    clean=1 kind=""
    for d in /sys/kernel/iommu_groups/"$grp"/devices/*; do
      c=$(cat "$d/class")
      case "$c" in
        0x0c03*) kind="usb" ;;
        0x0403*) [ -z "$kind" ] && kind="audio" || clean=0 ;;
        *) clean=0 ;;
      esac
    done
    [ "$clean" = 1 ] || { echo "[extra] group $grp not clean, skipping"; continue; }

    for d in /sys/kernel/iommu_groups/"$grp"/devices/*; do
      da=$(basename "$d"); da=${da#0000:}
      did=$(lspci -n -s "$da" | awk '{print $3}')
      case ",$EXTRA_IDS,$GPU_IDS," in *",$did,"*) continue ;; esac
      EXTRA_IDS="${EXTRA_IDS:+$EXTRA_IDS,}$did"
      echo "[extra] group $grp ($kind): $da -> $did"
    done
  done < <(lspci -nn | grep -iE "USB controller|Audio device.*8086|High Definition Audio.*8086")
fi

ALL_IDS="$GPU_IDS${EXTRA_IDS:+,$EXTRA_IDS}"

# ------------------------------------------------------------
# 4. vfio-pci binding
# ------------------------------------------------------------
VFIO_CONF="/etc/modprobe.d/vfio.conf"
VFIO_LINE="options vfio-pci ids=${ALL_IDS}"

if [ -f "$VFIO_CONF" ] && grep -qxF "$VFIO_LINE" "$VFIO_CONF"; then
  echo "[vfio-conf] Binding already present, skipping"
else
  echo "$VFIO_LINE" > "$VFIO_CONF"
  echo "[vfio-conf] Added binding: $ALL_IDS"
  CHANGES_MADE+=("vfio-pci binding")
  REBOOT_REQUIRED=true
fi

# ------------------------------------------------------------
# 5. Blacklist conflicting drivers
# ------------------------------------------------------------
BLACKLIST_CONF="/etc/modprobe.d/blacklist.conf"
BLACKLIST_MODULES=("nouveau" "nvidia" "nvidiafb")

for module in "${BLACKLIST_MODULES[@]}"; do
  LINE="blacklist $module"
  if [ -f "$BLACKLIST_CONF" ] && grep -qxF "$LINE" "$BLACKLIST_CONF"; then
    echo "[blacklist] $module already present, skipping"
  else
    echo "$LINE" >> "$BLACKLIST_CONF"
    echo "[blacklist] Added: $module"
    CHANGES_MADE+=("blacklist $module")
    REBOOT_REQUIRED=true
  fi
done

# ------------------------------------------------------------
# 6. softdep — ensure vfio-pci claims the device before nvidia/nouveau
# ------------------------------------------------------------
SOFTDEP_CONF="/etc/modprobe.d/vfio-softdep.conf"
SOFTDEP_LINES=(
  "softdep nvidia pre: vfio-pci"
  "softdep nouveau pre: vfio-pci"
  "softdep nvidiafb pre: vfio-pci"
)
if [ "$WS_FULL_PASSTHROUGH" = "1" ]; then
  SOFTDEP_LINES+=(
    "softdep xhci_pci pre: vfio-pci"
    "softdep ehci_pci pre: vfio-pci"
    "softdep snd_hda_intel pre: vfio-pci"
  )
fi

for line in "${SOFTDEP_LINES[@]}"; do
  if [ -f "$SOFTDEP_CONF" ] && grep -qxF "$line" "$SOFTDEP_CONF"; then
    echo "[softdep] Already present: $line"
  else
    echo "$line" >> "$SOFTDEP_CONF"
    echo "[softdep] Added: $line"
    CHANGES_MADE+=("softdep: $line")
    REBOOT_REQUIRED=true
  fi
done

# ------------------------------------------------------------
# 7. Rebuild initramfs only if something relevant changed
# ------------------------------------------------------------
INITRAMFS_TRIGGERS=("module" "vfio-pci binding" "blacklist" "softdep")
NEEDS_INITRAMFS=false

for change in "${CHANGES_MADE[@]+"${CHANGES_MADE[@]}"}"; do
  for trigger in "${INITRAMFS_TRIGGERS[@]}"; do
    if [[ "$change" == *"$trigger"* ]]; then
      NEEDS_INITRAMFS=true
    fi
  done
done

if [ "$NEEDS_INITRAMFS" = true ]; then
  update-initramfs -u -k all
  echo "[initramfs] Rebuilt"
fi

# ------------------------------------------------------------
# 8. IOMMU group diagnostic
# ------------------------------------------------------------
echo ""
echo "=== IOMMU group check for $GPU_PCI_ADDR ==="

FULL_PCI_ADDR="0000:${GPU_PCI_ADDR}"
IOMMU_GROUP_PATH="/sys/bus/pci/devices/${FULL_PCI_ADDR}/iommu_group"

if [ -e "$IOMMU_GROUP_PATH" ]; then
  GROUP_NUM=$(basename "$(readlink -f "$IOMMU_GROUP_PATH")")
  echo "GPU is in IOMMU group: $GROUP_NUM"
  echo "Devices in this group:"

  DEVICE_COUNT=0
  for dev in /sys/kernel/iommu_groups/"$GROUP_NUM"/devices/*; do
    DEV_ID=$(basename "$dev")
    DEV_DESC=$(lspci -s "${DEV_ID#0000:}" 2>/dev/null || echo "unknown")
    echo "  - $DEV_ID  ($DEV_DESC)"
    DEVICE_COUNT=$((DEVICE_COUNT + 1))
  done

  # Expect only the GPU + its audio function (2 devices) in a clean group
  if [ "$DEVICE_COUNT" -gt 2 ]; then
    echo ""
    echo "WARNING: IOMMU group has $DEVICE_COUNT devices, expected 2 (GPU + audio)."
    echo "This chipset may lack proper ACS isolation. Passthrough may still work,"
    echo "but ALL devices in this group must be passed together, or you may need"
    echo "an ACS override patch (use with caution, security implications)."
  else
    echo ""
    echo "OK: GPU is cleanly isolated in its own IOMMU group."
  fi
else
  echo "WARNING: could not read IOMMU group for $FULL_PCI_ADDR (is IOMMU active? reboot may be needed)"
fi

# ------------------------------------------------------------
# 9. Summary
# ------------------------------------------------------------
echo ""
echo "=== Summary ==="
if [ "${#CHANGES_MADE[@]}" -eq 0 ]; then
  echo "No changes needed. System already configured for GPU passthrough."
else
  echo "Changes applied:"
  for change in "${CHANGES_MADE[@]}"; do
    echo "  - $change"
  done
fi

if [ "$REBOOT_REQUIRED" = true ]; then
  echo ""
  echo ">>> REBOOT REQUIRED for changes to take effect <<<"
else
  echo ""
  echo "No reboot needed."
fi
