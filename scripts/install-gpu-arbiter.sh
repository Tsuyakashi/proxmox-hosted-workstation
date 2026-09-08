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
# The bpg Terraform provider can only upload content_type=snippets over SSH
# (upstream #2112 is wontfix), and this project is deliberately token-only /
# no-SSH for Terraform — so the snippet is installed out of band here and
# Terraform merely references `local:snippets/gpu-arbiter.sh`.

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

cat <<'EOF'

Next — attach the hookscript to the guests (Terraform does this via
hook_script_file_id, or by hand):

  pct set <ubuntu-ctid>  --hookscript local:snippets/gpu-arbiter.sh
  qm  set <windows-vmid> --hookscript local:snippets/gpu-arbiter.sh   # optional

Check:
  /var/lib/vz/snippets/gpu-arbiter.sh status
EOF
