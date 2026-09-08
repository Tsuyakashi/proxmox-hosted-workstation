#!/bin/bash
set -euo pipefail

# ============================================================
# Place the GPU arbiter on a Proxmox node. Idempotent. Run once per node.
# ============================================================
#
#   scp scripts/gpu-arbiter.sh scripts/workstation.sh scripts/install-gpu-arbiter.sh \
#       scripts/workstation-resume.service root@bare-pve:/root/
#   ssh root@bare-pve 'cd /root && bash install-gpu-arbiter.sh'
#
# The hookscript can't come from Terraform: bpg uploads snippets only over SSH
# (#2112 wontfix), and `hookscript:` on a guest config is root@pam-only in
# Proxmox anyway. So it's installed + attached here, on the node.

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"

install -d "$SNIPPETS_DIR"
install -m 0755 "$SRC_DIR/gpu-arbiter.sh"  "$SNIPPETS_DIR/gpu-arbiter.sh"
install -m 0755 "$SRC_DIR/workstation.sh"  /usr/local/sbin/workstation.sh
echo "[install] $SNIPPETS_DIR/gpu-arbiter.sh"
echo "[install] /usr/local/sbin/workstation.sh"

if [ -f "$SRC_DIR/workstation-resume.service" ]; then
  install -m 0644 "$SRC_DIR/workstation-resume.service" /etc/systemd/system/workstation-resume.service
  systemctl daemon-reload
  systemctl enable workstation-resume.service >/dev/null 2>&1 || true
  echo "[install] /etc/systemd/system/workstation-resume.service (enabled)"
fi

# attach to both workstation VMs (idempotent)
for name in windows-workstation ubuntu-workstation; do
  vmid=$(grep -sl "^name: ${name}\$" /etc/pve/qemu-server/*.conf 2>/dev/null | head -n1 | xargs -r basename | sed 's/\.conf$//')
  if [ -n "$vmid" ]; then
    qm set "$vmid" --hookscript local:snippets/gpu-arbiter.sh >/dev/null
    echo "[install] hookscript -> $name ($vmid)"
  else
    echo "[install] $name not created yet — re-run after 'terraform apply', or:"
    echo "          qm set <vmid> --hookscript local:snippets/gpu-arbiter.sh"
  fi
done

echo
echo "check:  /var/lib/vz/snippets/gpu-arbiter.sh status"
