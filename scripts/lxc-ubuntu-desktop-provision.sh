#!/bin/bash
set -euo pipefail

# ============================================================
# Ubuntu desktop LXC -> GNOME on the PHYSICAL monitors + Steam.
# Run INSIDE the container as root. Re-runnable.
# ============================================================
#
#   pct push <ctid> scripts/lxc-ubuntu-desktop-provision.sh /root/provision.sh
#   pct exec <ctid> -- env NVIDIA_VERSION=580.178.04 SEAT_USER=tsu bash /root/provision.sh
#
# NVIDIA: kernel module is on the HOST; here only the USERSPACE goes in
# (--no-kernel-module), version-matched to the host
# (`cat /sys/module/nvidia/version`). GTX 950 = Maxwell -> the 580 branch is
# the last one that supports it (verified: 590+ drops Maxwell).
#
# Display: the community-proven way for an *unprivileged* LXC on a physical
# monitor (ref: drakkein.me/articles/gaming-in-proxmox-lxc) is NO display
# manager and NO virtual terminal — start Xorg manually from a systemd
# service. Xorg runs with -keeptty so it never does VT ioctls; it opens
# /dev/dri/card0 directly and becomes DRM-master (the host is headless).

NVIDIA_VERSION="${NVIDIA_VERSION:-580.178.04}"
SEAT_USER="${SEAT_USER:-tsu}"
INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_DISCORD="${INSTALL_DISCORD:-1}"
INSTALL_VSCODE="${INSTALL_VSCODE:-1}"
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

export DEBIAN_FRONTEND=noninteractive
log() { echo "[provision] $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

# ------------------------------------------------------------
# 0. user
# ------------------------------------------------------------
if ! id "$SEAT_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SEAT_USER"
  echo "${SEAT_USER}:workstation" | chpasswd
fi
usermod -aG sudo,video,render,audio,input,plugdev "$SEAT_USER"
echo "${SEAT_USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/${SEAT_USER}
SEAT_HOME="$(getent passwd "$SEAT_USER" | cut -d: -f6)"

# ------------------------------------------------------------
# 1. Desktop + Xorg (no display manager)
# ------------------------------------------------------------
log "apt update + GNOME + Xorg"
dpkg --add-architecture i386
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  gnome-session gnome-shell gnome-control-center gnome-terminal nautilus \
  gnome-shell-extension-ubuntu-dock gnome-backgrounds \
  xserver-xorg xserver-xorg-core xserver-xorg-input-libinput xinit x11-xserver-utils \
  dbus-x11 dbus-user-session \
  mesa-utils mesa-vulkan-drivers mesa-vulkan-drivers:i386 vulkan-tools libvulkan1 libvulkan1:i386 \
  pipewire pipewire-pulse wireplumber \
  network-manager \
  curl wget ca-certificates gnupg pciutils kmod file

# make sure NO display manager grabs the seat
apt-get purge -y gdm3 2>/dev/null || true
systemctl set-default multi-user.target

# ------------------------------------------------------------
# 2. NVIDIA userspace (kernel module from the HOST)
# ------------------------------------------------------------
CUR="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
if [ "$CUR" = "$NVIDIA_VERSION" ]; then
  log "nvidia userspace $NVIDIA_VERSION already present"
else
  log "nvidia userspace $NVIDIA_VERSION (--no-kernel-module)"
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  [ -f "$RUN" ] || curl -fL --progress-bar -o "$RUN" "${RUN_URL_BASE}/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  sh "$RUN" --silent --no-kernel-module --no-drm --install-libglvnd \
    --install-compat32-libs --no-questions --ui=none
  # the .run's partial libglvnd -> `undefined symbol: _glapi_tls_Current`;
  # restore the distro GLVND dispatch (NVIDIA vendor libs keep working).
  apt-get install --reinstall -y \
    libglvnd0 libglx0 libgl1 libopengl0 libegl1 libgles2 \
    libglvnd0:i386 libgl1:i386 libglx0:i386
  ldconfig
fi

# ------------------------------------------------------------
# 3. Xorg config
# ------------------------------------------------------------
install -d /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/10-nvidia-seat.conf <<'EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "AutoAddGPU"   "false"
    Option "BlankTime"    "0"
    Option "StandbyTime"  "0"
    Option "SuspendTime"  "0"
    Option "OffTime"      "0"
EndSection

Section "Device"
    Identifier "nvidia"
    Driver     "nvidia"
    BusID      "PCI:1:0:0"
    Option     "AllowEmptyInitialConfiguration" "true"
    Option     "PrimaryGPU" "yes"
    Option     "ConnectedMonitor" "DFP"
EndSection

Section "Screen"
    Identifier "screen0"
    Device     "nvidia"
EndSection
EOF

# non-root user may start X with the rights it needs (no logind seat here)
cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# ------------------------------------------------------------
# 4. manual session: systemd service -> xinit -> gnome-session
# ------------------------------------------------------------
cat >/usr/local/bin/workstation-xsession <<'EOF'
#!/bin/bash
export XDG_SESSION_TYPE=x11
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
xset s off -dpms 2>/dev/null || true
exec dbus-run-session -- gnome-session --session=ubuntu
EOF
chmod +x /usr/local/bin/workstation-xsession

cat >/usr/local/bin/workstation-session <<'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
# vt7 = the host tty passed into the CT by lxc-ct-passthrough.sh; -keeptty so
# Xorg never issues VT ioctls (unprivileged CT can't).
exec /usr/bin/xinit /usr/local/bin/workstation-xsession -- \
  /usr/bin/X :0 vt7 -keeptty -nolisten tcp -novtswitch
EOF
chmod +x /usr/local/bin/workstation-session

cat >/etc/systemd/system/workstation-session.service <<EOF
[Unit]
Description=Physical-seat GNOME session (no display manager)
After=systemd-user-sessions.service dbus.service network-online.target
Wants=network-online.target

[Service]
User=${SEAT_USER}
PAMName=login
TTYPath=/dev/tty7
WorkingDirectory=${SEAT_HOME}
Environment=HOME=${SEAT_HOME}
ExecStart=/usr/local/bin/workstation-session
Restart=on-failure
RestartSec=3
# keep trying — the monitor should always come back
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable workstation-session.service

# ------------------------------------------------------------
# 5. Steam / Discord / VS Code
# ------------------------------------------------------------
if [ "$INSTALL_STEAM" = 1 ]; then
  log "steam (+i386)"
  add-apt-repository -y multiverse || true
  apt-get update
  echo "steam steam/question select 'I AGREE'" | debconf-set-selections
  echo "steam steam/license note ''" | debconf-set-selections
  apt-get install -y steam-installer || {
    curl -fL -o /root/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb
    apt-get install -y /root/steam.deb
  }
fi
if [ "$INSTALL_DISCORD" = 1 ]; then
  log "discord"
  curl -fL -o /root/discord.deb "https://discord.com/api/download?platform=linux&format=deb"
  apt-get install -y /root/discord.deb
fi
if [ "$INSTALL_VSCODE" = 1 ]; then
  log "vscode"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    >/etc/apt/sources.list.d/vscode.list
  apt-get update && apt-get install -y code
fi

# ------------------------------------------------------------
# 6. sanity
# ------------------------------------------------------------
echo ""
echo "=== checks ==="
ls -l /dev/dri /dev/fb0 /dev/tty7 /dev/nvidia0 2>&1 || echo "!! seat nodes missing — re-run lxc-ct-passthrough.sh, restart CT"
nvidia-smi -L || echo "!! nvidia-smi failed"
echo ""
echo "Restart the CT (workstation.sh start ubuntu). The monitors should light"
echo "with the GNOME session for user '${SEAT_USER}'."
echo "If dark:  journalctl -u workstation-session -b   and   ~${SEAT_USER}/.local/share/xorg/Xorg.0.log"
