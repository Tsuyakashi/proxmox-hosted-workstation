#!/bin/bash
set -euo pipefail

# ============================================================
# Ubuntu LXC -> XFCE desktop on the PHYSICAL monitors + Steam/Discord/Chrome.
# Run INSIDE the container as root. Re-runnable.
# ============================================================
#
#   pct push <ctid> scripts/lxc-ubuntu-desktop-provision.sh /root/provision.sh
#   pct exec <ctid> -- env NVIDIA_VERSION=580.178.04 SEAT_USER=tsu bash /root/provision.sh
#
# WHY XFCE, not GNOME: modern GNOME needs a real systemd-logind session, which
# an unprivileged LXC can't create (`CreateSession failed`). Plasma 6.6 on
# Ubuntu 26.04 is Wayland-only (no startplasma-x11). XFCE is pure X11 and
# starts standalone.
#
# WHY manual Xorg, no display manager: no virtual terminals in an LXC. A
# systemd service runs `xinit ... X :0 vt7 -keeptty -novtswitch`; Xorg opens
# /dev/dri/card0 directly and becomes DRM-master (the Proxmox host is
# headless, nothing else holds it). Ref: drakkein.me/articles/gaming-in-proxmox-lxc
#
# WHY evdev, not libinput, for input: libinput refuses to work without udev
# metadata, and an unprivileged LXC has no working udev. evdev opens the
# /dev/input/event* nodes directly. gen-xorg-input builds the sections from
# /proc/bus/input/devices at each start.
#
# NVIDIA: kernel module is on the HOST (lxc-nvidia-host-setup.sh); here only
# the USERSPACE, version-matched to `cat /sys/module/nvidia/version`. The
# GTX 950 is Maxwell -> the 580 branch is the LAST that supports it.
#
# Prereqs on the host: lxc-nvidia-host-setup.sh (nvidia driver + nvidia-drm
# modeset=1 fbdev=1) and lxc-ct-passthrough.sh <ctid> (dev nodes + the seat
# block: /dev/fb0, /dev/tty7, /dev/vga_arbiter, cgroup 4/29/226).

NVIDIA_VERSION="${NVIDIA_VERSION:-580.178.04}"
SEAT_USER="${SEAT_USER:-tsu}"
SEAT_TTY="${SEAT_TTY:-7}"
INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_DISCORD="${INSTALL_DISCORD:-1}"
INSTALL_CHROME="${INSTALL_CHROME:-1}"
INSTALL_VSCODE="${INSTALL_VSCODE:-1}"
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

export DEBIAN_FRONTEND=noninteractive
log() { echo "[provision] $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

# ------------------------------------------------------------
# 0. seat user + lingering systemd --user
# ------------------------------------------------------------
if ! id "$SEAT_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SEAT_USER"
  echo "${SEAT_USER}:workstation" | chpasswd
  log "created user ${SEAT_USER} (password: workstation — change it)"
fi
usermod -aG sudo,video,render,audio,input,plugdev "$SEAT_USER"
echo "${SEAT_USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/${SEAT_USER}
loginctl enable-linger "$SEAT_USER"
SEAT_HOME="$(getent passwd "$SEAT_USER" | cut -d: -f6)"
SEAT_UID="$(id -u "$SEAT_USER")"

# ------------------------------------------------------------
# 1. XFCE + Xorg + evdev
# ------------------------------------------------------------
log "apt update + XFCE + Xorg"
dpkg --add-architecture i386
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings \
  thunar xfce4-terminal xfce4-appfinder xfce4-notifyd \
  xfce4-pulseaudio-plugin xfce4-whiskermenu-plugin xfce4-taskmanager \
  xfce4-screenshooter tumbler \
  xserver-xorg xserver-xorg-core xserver-xorg-input-evdev xinit x11-xserver-utils xinput \
  dbus-x11 \
  mesa-utils mesa-vulkan-drivers mesa-vulkan-drivers:i386 vulkan-tools libvulkan1 libvulkan1:i386 \
  pipewire pipewire-pulse wireplumber pavucontrol \
  network-manager network-manager-gnome policykit-1-gnome \
  fonts-dejavu fonts-liberation adwaita-icon-theme \
  locales curl wget ca-certificates gnupg pciutils kmod file

# generate a UTF-8 locale (zenity / GTK complain about "C" otherwise)
sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8

# no display manager
apt-get purge -y gdm3 lightdm sddm 2>/dev/null || true
systemctl set-default multi-user.target
systemctl enable NetworkManager

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
    Option "DontVTSwitch"   "true"
    Option "AutoAddDevices" "false"
    Option "AutoAddGPU"     "false"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Device"
    Identifier "nvidia"
    Driver     "nvidia"
    BusID      "PCI:1:0:0"
    Option     "AllowEmptyInitialConfiguration" "true"
    Option     "HardDPMS" "false"
EndSection

Section "Screen"
    Identifier "screen0"
    Device     "nvidia"
EndSection
EOF
# Monitor arrangement (left/right, refresh rate) is per-rig: set it once in
# XFCE "Display" settings — it persists to ~/.config/xfce4/xfconf. Or add an
# nvidia `Option "metamodes"` line to the Device section above.

cat >/etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# ------------------------------------------------------------
# 4. input generator: /proc/bus/input/devices -> evdev sections
# ------------------------------------------------------------
cat >/usr/local/bin/gen-xorg-input <<'EOF'
#!/bin/bash
# Build explicit evdev InputDevice sections (no udev in the CT for libinput).
OUT=/etc/X11/xorg.conf.d/20-evdev-explicit.conf
declare -A SEEN
POINTER=""; KEYBOARD=""; EXTRA=()
while read -r line; do
  case "$line" in "H: Handlers="*) ;; *) continue ;; esac
  ev=""; for t in $line; do [[ $t =~ ^event[0-9]+$ ]] && ev="/dev/input/$t"; done
  [ -n "$ev" ] && [ -e "$ev" ] || continue
  [ -n "${SEEN[$ev]:-}" ] && continue; SEEN[$ev]=1
  if   [[ $line == *mouse*    && -z $POINTER  ]]; then POINTER=$ev
  elif [[ $line == *kbd*leds* && -z $KEYBOARD ]]; then KEYBOARD=$ev
  elif [[ $line == *kbd*      ]]; then EXTRA+=("$ev")
  elif [[ $line == *mouse*    ]]; then EXTRA+=("$ev")
  fi
done < /proc/bus/input/devices
{
  echo 'Section "ServerLayout"'
  echo '    Identifier "layout0"'
  echo '    Screen 0 "screen0"'
  echo '    InputDevice "kbd0" "CoreKeyboard"'
  echo '    InputDevice "ptr0" "CorePointer"'
  n=0; for e in "${EXTRA[@]}"; do echo "    InputDevice \"ex${n}\" \"SendCoreEvents\""; n=$((n+1)); done
  echo 'EndSection'
  printf 'Section "InputDevice"\n    Identifier "kbd0"\n    Driver "evdev"\n    Option "Device" "%s"\n    Option "XkbLayout" "us,ru"\n    Option "XkbOptions" "grp:alt_shift_toggle"\nEndSection\n' "${KEYBOARD:-/dev/input/event0}"
  printf 'Section "InputDevice"\n    Identifier "ptr0"\n    Driver "evdev"\n    Option "Device" "%s"\nEndSection\n' "${POINTER:-/dev/input/mice}"
  n=0; for e in "${EXTRA[@]}"; do printf 'Section "InputDevice"\n    Identifier "ex%s"\n    Driver "evdev"\n    Option "Device" "%s"\nEndSection\n' "$n" "$e"; n=$((n+1)); done
} > "$OUT"
EOF
chmod +x /usr/local/bin/gen-xorg-input
echo "${SEAT_USER} ALL=(root) NOPASSWD: /usr/local/bin/gen-xorg-input" >/etc/sudoers.d/gen-xorg-input
/usr/local/bin/gen-xorg-input

# ------------------------------------------------------------
# 5. manual session: systemd service -> xinit -> startxfce4
# ------------------------------------------------------------
cat >/usr/local/bin/workstation-xsession <<'EOF'
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
xset s off -dpms 2>/dev/null || true
exec dbus-launch --exit-with-session startxfce4
EOF
chmod +x /usr/local/bin/workstation-xsession

cat >/usr/local/bin/workstation-session <<EOF
#!/bin/bash
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
mkdir -p "\$XDG_RUNTIME_DIR"; chmod 700 "\$XDG_RUNTIME_DIR"
sudo /usr/local/bin/gen-xorg-input 2>/dev/null || true
exec /usr/bin/xinit /usr/local/bin/workstation-xsession -- \\
  /usr/bin/X :0 vt${SEAT_TTY} -keeptty -nolisten tcp -novtswitch
EOF
chmod +x /usr/local/bin/workstation-session

cat >/etc/systemd/system/workstation-session.service <<EOF
[Unit]
Description=Physical-seat XFCE session (no display manager)
After=systemd-user-sessions.service dbus.service network-online.target
Wants=network-online.target

[Service]
User=${SEAT_USER}
PAMName=login
TTYPath=/dev/tty${SEAT_TTY}
WorkingDirectory=${SEAT_HOME}
Environment=HOME=${SEAT_HOME}
ExecStart=/usr/local/bin/workstation-session
Restart=on-failure
RestartSec=3
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable workstation-session.service

# ------------------------------------------------------------
# 6. Steam / Discord / Chrome / VS Code  (each non-fatal)
# ------------------------------------------------------------
app() { set +e; "$@"; set -e; }

if [ "$INSTALL_STEAM" = 1 ]; then
  log "steam (+i386)"
  add-apt-repository -y multiverse || true
  apt-get update
  echo "steam steam/question select 'I AGREE'" | debconf-set-selections
  echo "steam steam/license note ''" | debconf-set-selections
  app apt-get install -y steam-installer || {
    curl -fL -o /root/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb && app apt-get install -y /root/steam.deb
  }
fi

if [ "$INSTALL_DISCORD" = 1 ]; then
  log "discord"
  for i in 1 2 3 4 5; do curl -fL --retry 3 -o /root/discord.deb "https://discord.com/api/download?platform=linux&format=deb" && break || sleep 6; done
  [ -s /root/discord.deb ] && app apt-get install -y /root/discord.deb || log "discord skipped"
fi

install -d -m 0755 /etc/apt/keyrings
if [ "$INSTALL_CHROME" = 1 ]; then
  log "chrome"
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list
  apt-get update -qq && app apt-get install -y google-chrome-stable || log "chrome skipped"
fi

if [ "$INSTALL_VSCODE" = 1 ]; then
  log "vscode"
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" >/etc/apt/sources.list.d/vscode.list
  apt-get update -qq && app apt-get install -y code || log "vscode skipped"
fi

# ------------------------------------------------------------
# 7. sanity
# ------------------------------------------------------------
echo ""
echo "=== checks ==="
ls -l /dev/dri /dev/fb0 /dev/tty${SEAT_TTY} /dev/nvidia0 2>&1 || echo "!! seat nodes missing — re-run lxc-ct-passthrough.sh, restart CT"
nvidia-smi -L || echo "!! nvidia-smi failed (host/CT driver version mismatch?)"
echo "installed: $(dpkg -l steam-installer discord google-chrome-stable code 2>/dev/null | grep -c '^ii') / 4 apps"
echo ""
echo "Restart the CT (from a stopped state:  workstation.sh start ubuntu)."
echo "The monitors light with XFCE for '${SEAT_USER}'. First Xorg log:"
echo "  ${SEAT_HOME}/.local/share/xorg/Xorg.0.log   /   journalctl -u workstation-session -b"
echo "Arrange monitors + refresh rate once in XFCE 'Display' settings (it persists)."
