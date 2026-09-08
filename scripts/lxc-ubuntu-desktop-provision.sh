#!/bin/bash
set -euo pipefail

# ============================================================
# Turn the fresh Ubuntu LXC into a GPU-accelerated desktop workstation.
# Run INSIDE the container. Re-runnable.
# ============================================================
#
#   pct push <ctid> scripts/lxc-ubuntu-desktop-provision.sh /root/provision.sh
#   pct exec <ctid> -- env NVIDIA_VERSION=580.178.04 bash /root/provision.sh
#
# NVIDIA_VERSION MUST equal the host's `cat /sys/module/nvidia/version` — only
# the USERSPACE half is installed here (--no-kernel-module); the kernel module
# lives on the Proxmox host.
#
# Toggle pieces with env vars (all default on): INSTALL_STEAM, INSTALL_DISCORD,
# INSTALL_VSCODE, INSTALL_SUNSHINE, ENABLE_XRDP. DESKTOP=ubuntu-desktop-minimal.

NVIDIA_VERSION="${NVIDIA_VERSION:-580.178.04}"
DESKTOP="${DESKTOP:-ubuntu-desktop-minimal}"
ENABLE_XRDP="${ENABLE_XRDP:-1}"
INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_DISCORD="${INSTALL_DISCORD:-1}"
INSTALL_VSCODE="${INSTALL_VSCODE:-1}"
INSTALL_SUNSHINE="${INSTALL_SUNSHINE:-1}"
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

export DEBIAN_FRONTEND=noninteractive
log() { echo "[provision] $*"; }

# ------------------------------------------------------------
# 1. Base desktop (standard archive, NOT a cloud image)
# ------------------------------------------------------------
log "apt update + base desktop ($DESKTOP)"
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  "$DESKTOP" \
  dbus-user-session systemd-container \
  mesa-utils mesa-vulkan-drivers vulkan-tools libvulkan1 \
  xterm curl wget ca-certificates gnupg kmod pciutils file \
  pipewire pipewire-pulse wireplumber

# gdm on a VT is pointless in a CT; xrdp spawns its own X per session.
systemctl set-default graphical.target

if [ "$ENABLE_XRDP" = 1 ]; then
  log "xrdp"
  apt-get install -y --no-install-recommends xrdp xorgxrdp
  adduser xrdp ssl-cert || true
  # force an Xorg GNOME session (Wayland doesn't tunnel over xrdp)
  cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if [ -r /etc/profile ]; then . /etc/profile; fi
export XDG_SESSION_TYPE=x11
export GNOME_SHELL_SESSION_MODE=ubuntu
exec /usr/bin/dbus-launch --exit-with-session /usr/bin/gnome-session --session=ubuntu
EOF
  chmod +x /etc/xrdp/startwm.sh
  systemctl enable xrdp
fi

# ------------------------------------------------------------
# 2. NVIDIA userspace driver (kernel module comes from the HOST)
# ------------------------------------------------------------
CUR="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
if [ "$CUR" = "$NVIDIA_VERSION" ]; then
  log "nvidia userspace $NVIDIA_VERSION already present"
else
  log "nvidia userspace $NVIDIA_VERSION (--no-kernel-module)"
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  [ -f "$RUN" ] || curl -fL --progress-bar -o "$RUN" "${RUN_URL_BASE}/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  # 32-bit libs are needed by Steam/Proton.
  dpkg --add-architecture i386
  apt-get update
  sh "$RUN" --silent --no-kernel-module --no-drm --install-libglvnd \
    --install-compat32-libs --no-questions --ui=none
  # The .run's --install-libglvnd overwrites the distro GLVND dispatch libs with
  # a partial set -> Mesa/llvmpipe apps (Sunshine, some Electron) hit
  # `undefined symbol: _glapi_tls_Current`. Restore the distro dispatch; the
  # NVIDIA vendor libs (libGLX_nvidia / libEGL_nvidia) keep working via GLVND.
  apt-get install --reinstall -y \
    libglvnd0 libglx0 libgl1 libopengl0 libegl1 libgles2 \
    libglvnd0:i386 libgl1:i386 libglx0:i386
  ldconfig
fi

# ------------------------------------------------------------
# 3. Steam
# ------------------------------------------------------------
if [ "$INSTALL_STEAM" = 1 ]; then
  log "steam (+ i386)"
  dpkg --add-architecture i386
  # steam-installer lives in multiverse
  add-apt-repository -y multiverse || true
  apt-get update
  echo "steam steam/question select 'I AGREE'" | debconf-set-selections
  echo "steam steam/license note ''" | debconf-set-selections
  apt-get install -y steam-installer || {
    curl -fL -o /root/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb
    apt-get install -y /root/steam.deb
  }
fi

# ------------------------------------------------------------
# 4. Discord
# ------------------------------------------------------------
if [ "$INSTALL_DISCORD" = 1 ]; then
  log "discord"
  curl -fL -o /root/discord.deb "https://discord.com/api/download?platform=linux&format=deb"
  apt-get install -y /root/discord.deb
fi

# ------------------------------------------------------------
# 5. VS Code (Microsoft apt repo)
# ------------------------------------------------------------
if [ "$INSTALL_VSCODE" = 1 ]; then
  log "vscode"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    >/etc/apt/sources.list.d/vscode.list
  apt-get update
  apt-get install -y code
fi

# ------------------------------------------------------------
# 6. Sunshine (GPU game-streaming host — Moonlight clients)
# ------------------------------------------------------------
if [ "$INSTALL_SUNSHINE" = 1 ]; then
  log "sunshine"
  set +e
  REL="$(. /etc/os-release; echo "${VERSION_ID:-24.04}")"
  API=$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest)
  # LizardByte asset: sunshine_<ver>-1+ubuntu<rel>_amd64.deb  (fall back 24.04)
  SUN_URL=$(printf '%s' "$API" | grep -oE "https://[^\"]+ubuntu${REL}_amd64\.deb" | head -1)
  [ -n "$SUN_URL" ] || SUN_URL=$(printf '%s' "$API" | grep -oE 'https://[^"]+ubuntu24\.04_amd64\.deb' | head -1)
  if [ -n "$SUN_URL" ] && curl -fL -o /root/sunshine.deb "$SUN_URL"; then
    apt-get install -y /root/sunshine.deb || echo "[provision] sunshine dpkg failed — skip"
  else
    echo "[provision] sunshine: no matching .deb for $REL — skip (install by hand if wanted)"
  fi
  set -e
fi

# ------------------------------------------------------------
# 7. Sanity
# ------------------------------------------------------------
echo ""
echo "=== checks ==="
ls -l /dev/nvidia* /dev/dri 2>&1 || echo "!! GPU nodes missing — check lxc-ct-passthrough.sh + host driver"
nvidia-smi || echo "!! nvidia-smi failed — version mismatch with host, or nodes not passed"
echo ""
echo "Done. Then:  pct reboot <ctid>"
echo "Create your user:  adduser <you> && usermod -aG sudo,video,render,audio <you>"
[ "$ENABLE_XRDP" = 1 ] && echo "RDP to the CT IP:3389 as that user."
[ "$INSTALL_SUNSHINE" = 1 ] && echo "Sunshine web UI: https://<ct-ip>:47990  (run 'sunshine' once in the desktop session to set the admin creds)."
