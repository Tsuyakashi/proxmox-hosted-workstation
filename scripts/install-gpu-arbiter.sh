#!/bin/bash
set -euo pipefail

# ============================================================
# Place the GPU arbiter on a Proxmox node. Idempotent. Run once per node.
# ============================================================
#
#   scp scripts/gpu-arbiter.sh scripts/workstation.sh scripts/install-gpu-arbiter.sh \
#       scripts/workstation-resume.service root@<node>:/root/
#   scp host/<node>/gpu-arbiter.conf root@<node>:/root/gpu-arbiter.conf   # if the node has one
#   ssh root@<node> 'cd /root && bash install-gpu-arbiter.sh'
#
# The bpg Terraform provider can only upload content_type=snippets over SSH
# (upstream #2112 is wontfix), and this project is deliberately token-only /
# no-SSH for Terraform — so the snippet is installed out of band here and
# Terraform merely references `local:snippets/gpu-arbiter.sh`.

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"
CONF_DST=/etc/default/gpu-arbiter

install -d "$SNIPPETS_DIR"
install -m 0755 "$SRC_DIR/gpu-arbiter.sh"  "$SNIPPETS_DIR/gpu-arbiter.sh"
install -m 0755 "$SRC_DIR/workstation.sh"  /usr/local/sbin/workstation.sh
echo "[install] $SNIPPETS_DIR/gpu-arbiter.sh"
echo "[install] /usr/local/sbin/workstation.sh"

# Per-node addresses (USB_FUNCS etc). Built-in defaults are bare-pve's Intel
# addresses — on any other board they can point at non-USB devices.
if [ -f "$SRC_DIR/gpu-arbiter.conf" ]; then
  install -m 0644 "$SRC_DIR/gpu-arbiter.conf" "$CONF_DST"
  echo "[install] $CONF_DST"
elif [ -f "$CONF_DST" ]; then
  echo "[install] $CONF_DST kept (no gpu-arbiter.conf next to installer)"
else
  echo "[install] WARNING: no $CONF_DST — built-in defaults are bare-pve (Intel) addresses"
fi

if [ -f "$SRC_DIR/workstation-resume.service" ]; then
  install -m 0644 "$SRC_DIR/workstation-resume.service" /etc/systemd/system/workstation-resume.service
  systemctl daemon-reload
  systemctl enable workstation-resume.service >/dev/null 2>&1 || true
  echo "[install] /etc/systemd/system/workstation-resume.service (enabled)"
fi

cat <<'EOF'

Next — attach the hookscript to the guests. `hookscript:` is root@pam-only,
so the API token (Terraform) can't set it — do it on the node (for the CT,
lxc-ct-passthrough.sh <ctid> already does):

  pct set <ubuntu-ctid>  --hookscript local:snippets/gpu-arbiter.sh
  qm  set <windows-vmid> --hookscript local:snippets/gpu-arbiter.sh

Check:
  /var/lib/vz/snippets/gpu-arbiter.sh status
EOF
