#!/bin/bash
set -euo pipefail

# ============================================================
# Ubuntu 26.04 LXC -> full GNOME desktop (ubuntu-desktop + GDM) on the
# PHYSICAL monitors. Run INSIDE the container as root. Re-runnable.
# ============================================================
#
#   pct push <ctid> scripts/lxc-ubuntu-desktop-provision.sh /root/provision.sh
#   pct exec <ctid> -- env NVIDIA_VERSION=580.178.04 SEAT_USER=tsu bash /root/provision.sh
#
# WHY THIS WORKS NOW (the earlier XFCE build couldn't): env/ubuntu is a
# PRIVILEGED CT with `lxc.mount.auto: proc:rw sys:rw` and `apparmor:
# unconfined` (scripts/lxc-ct-passthrough.sh). That gives a working
# systemd-udevd + systemd-logind: `loginctl seat-status seat0` shows
# `[MASTER] drm:card0`, so GDM can start a real graphical session and
# GNOME 50 (Wayland-only since GNOME 49) can take DRM master. libinput and
# PipeWire's ALSA discovery work natively too — no evdev / manual-node hacks.
#
# NVIDIA: kernel module is on the HOST (lxc-nvidia-host-setup.sh); here only
# the USERSPACE, version-matched to `cat /sys/module/nvidia/version`. GTX 950
# is Maxwell -> the 580 branch is the LAST that supports it.
#
# Host prereqs: lxc-nvidia-host-setup.sh (nvidia driver + nvidia-drm
# modeset=1 fbdev=1) and lxc-ct-passthrough.sh <ctid>.

NVIDIA_VERSION="${NVIDIA_VERSION:-580.178.04}"
SEAT_USER="${SEAT_USER:-tsu}"
SEAT_PASSWORD="${SEAT_PASSWORD:-workstation}"
INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_DISCORD="${INSTALL_DISCORD:-1}"
INSTALL_CHROME="${INSTALL_CHROME:-1}"
INSTALL_VSCODE="${INSTALL_VSCODE:-1}"
RUN_URL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

export DEBIAN_FRONTEND=noninteractive
log() { echo "[provision] $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

# ------------------------------------------------------------
# 0. seat user
# ------------------------------------------------------------
if ! id "$SEAT_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SEAT_USER"
  log "created user ${SEAT_USER}"
fi
echo "${SEAT_USER}:${SEAT_PASSWORD}" | chpasswd
usermod -aG sudo,video,render,audio,input,plugdev "$SEAT_USER"
echo "${SEAT_USER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/${SEAT_USER}
loginctl enable-linger "$SEAT_USER" 2>/dev/null || true
SEAT_HOME="$(getent passwd "$SEAT_USER" | cut -d: -f6)"
SEAT_UID="$(id -u "$SEAT_USER")"

# ------------------------------------------------------------
# 1. network reliability + full GNOME desktop + locale
# ------------------------------------------------------------
# The CT gets a link-local IPv6 but no global v6 route, yet DNS returns AAAA
# -> apps hit "Connection reset". Prefer IPv4 + disable v6.
cat >/etc/gai.conf <<'EOF'
precedence ::ffff:0:0/96  100
precedence ::1/128        50
precedence ::/0           40
precedence 2002::/16      30
EOF
cat >/etc/sysctl.d/99-no-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system >/dev/null 2>&1 || true
cat >/etc/apt/apt.conf.d/99-workstation <<'EOF'
Acquire::Retries "20";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "30";
EOF

# apparmor.service can't load profiles inside a container (the CT runs
# unconfined anyway) — mask it so systemd isn't "degraded".
systemctl mask apparmor.service 2>/dev/null || true

# snapd cannot seed in a container (no loop mounts / squashfs / apparmor for
# snap-confine): `snap wait system seed.loaded` hangs forever and deadlocks
# the dpkg configure of snapd — and then every snap-transitional .deb
# (firefox, thunderbird, snap-store, firmware-updater...) hangs its
# maintainer script on `snap install`. Stub `snap` to succeed instantly and
# mask the units BEFORE pulling ubuntu-desktop. GNOME itself is all .deb; the
# only loss is the handful of default snaps (the user runs Chrome anyway).
if [ ! -e /usr/bin/snap.real ] && [ -e /usr/bin/snap ]; then
  dpkg-divert --local --rename --divert /usr/bin/snap.real --add /usr/bin/snap
fi
cat >/usr/bin/snap <<'EOF'
#!/bin/bash
# stub — this container can't run snaps. Succeed so transitional .deb
# maintainer scripts neither hang nor fail. Real binary: /usr/bin/snap.real
case "${1:-}" in
  list) echo "No snaps are installed yet."; exit 0 ;;
  info|find) echo "name: ${2:-unknown}"; exit 0 ;;
  version) echo "snap    stub"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x /usr/bin/snap
systemctl mask snapd.service snapd.socket snapd.seeded.service \
  snapd.apparmor.service snapd.autoimport.service snapd.core-fixup.service \
  snapd.recovery-chooser-trigger.service snapd.snap-repair.timer \
  snapd.system-shutdown.service 2>/dev/null || true

log "apt update + full-upgrade + base tools"
apt-get update
apt-get install -y curl wget ca-certificates gnupg software-properties-common
apt-get -y full-upgrade

log "ubuntu-desktop (full GNOME + GDM) — big download; snap parts are no-ops"
apt-get install -y ubuntu-desktop
apt-mark hold firefox thunderbird 2>/dev/null || true

sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8

# ------------------------------------------------------------
# 2. NVIDIA userspace (kernel module from the HOST, versions MUST match)
# ------------------------------------------------------------
CUR="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
if [ "$CUR" = "$NVIDIA_VERSION" ]; then
  log "nvidia userspace $NVIDIA_VERSION already present"
else
  log "nvidia userspace $NVIDIA_VERSION (--no-kernel-module)"
  dpkg --add-architecture i386; apt-get update
  apt-get install -y --no-install-recommends \
    libc6-dev pkg-config libglvnd-dev \
    mesa-utils vulkan-tools libvulkan1 libvulkan1:i386
  RUN="/root/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
  [ -f "$RUN" ] || curl -4 -fL --retry 20 --retry-all-errors --progress-bar \
    -o "$RUN" "${RUN_URL_BASE}/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
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
# 3. GDM: autologin the seat user, force Wayland even on NVIDIA
# ------------------------------------------------------------
install -d /etc/gdm3
cat >/etc/gdm3/custom.conf <<EOF
[daemon]
WaylandEnable=true
AutomaticLoginEnable=true
AutomaticLogin=${SEAT_USER}

[security]

[xdmcp]

[chooser]

[debug]
EOF
# Ubuntu ships /usr/lib/udev/rules.d/61-gdm.rules which disables Wayland when
# the proprietary nvidia driver is loaded. nvidia-drm is in `modeset=1`
# (host) so KMS/GBM works — allow Wayland.
if [ -f /usr/lib/udev/rules.d/61-gdm.rules ]; then
  sed -i 's/^\(.*DISABLE_WAYLAND.*\)$/# \1/' /usr/lib/udev/rules.d/61-gdm.rules || true
fi
mkdir -p /etc/udev/rules.d
ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules
# nvidia-drm needs modeset for Wayland; the host sets it, restate for the CT view
echo 'options nvidia-drm modeset=1 fbdev=1' >/etc/modprobe.d/nvidia-drm.conf

systemctl set-default graphical.target
systemctl enable gdm3 2>/dev/null || systemctl enable gdm 2>/dev/null || true

# ------------------------------------------------------------
# 4. coldplug udev at boot (bind-mounted nodes fire no uevents)
# ------------------------------------------------------------
# systemd-udev-trigger runs early; make sure it re-runs after our device
# binds are in place and mark card0 master-of-seat for logind.
cat >/etc/udev/rules.d/99-workstation-seat.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="card0", TAG+="seat", TAG+="master-of-seat"
SUBSYSTEM=="usb", MODE="0666"
SUBSYSTEM=="input", MODE="0664", GROUP="input"
KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
EOF
cat >/etc/systemd/system/workstation-coldplug.service <<'EOF'
[Unit]
Description=Re-trigger udev coldplug for bind-mounted devices
DefaultDependencies=no
After=systemd-udevd.service systemd-udev-trigger.service
Before=systemd-logind.service gdm.service
[Service]
Type=oneshot
ExecStart=/usr/bin/udevadm trigger --action=add
ExecStart=/usr/bin/udevadm settle --timeout=20
RemainAfterExit=yes
[Install]
WantedBy=sysinit.target
EOF
systemctl enable workstation-coldplug.service

# ------------------------------------------------------------
# 5. GNOME defaults: Ubuntu look, dual-monitor layout, no idle/lock
# ------------------------------------------------------------
install -d -o "$SEAT_USER" -g "$SEAT_USER" "${SEAT_HOME}/.config"
# Monitor layout: AOC 144Hz on HDMI (left, primary), Philips 60Hz on DVI-I
# (right). Adjust in Settings -> Displays if the physical sides differ; GNOME
# persists it back here.
cat >"${SEAT_HOME}/.config/monitors.xml" <<'EOF'
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x><y>0</y><scale>1</scale><primary>yes</primary>
      <monitor><monitorspec>
        <connector>HDMI-1</connector><vendor>AOC</vendor><product>0x0</product><serial>0x0</serial>
      </monitorspec><mode><width>1920</width><height>1080</height><rate>143.981</rate></mode></monitor>
    </logicalmonitor>
    <logicalmonitor>
      <x>1920</x><y>0</y><scale>1</scale>
      <monitor><monitorspec>
        <connector>DVI-I-1</connector><vendor>PHL</vendor><product>0x0</product><serial>0x0</serial>
      </monitorspec><mode><width>1920</width><height>1080</height><rate>60.000</rate></mode></monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF
chown "$SEAT_USER:$SEAT_USER" "${SEAT_HOME}/.config/monitors.xml"
# GDM greeter gets the same layout (runs as Debian-gdm)
install -d -o Debian-gdm -g Debian-gdm /var/lib/gdm3/.config 2>/dev/null || true
cp "${SEAT_HOME}/.config/monitors.xml" /var/lib/gdm3/.config/monitors.xml 2>/dev/null || true
chown -R Debian-gdm:Debian-gdm /var/lib/gdm3/.config 2>/dev/null || true

sudo -u "$SEAT_USER" dbus-run-session -- bash -c '
  gsettings set org.gnome.desktop.session idle-delay 0
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
  gsettings set org.gnome.desktop.screensaver lock-enabled false
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  gsettings set org.gnome.desktop.input-sources sources "[('"'"'xkb'"'"', '"'"'us'"'"'), ('"'"'xkb'"'"', '"'"'ru'"'"')]"
  gsettings set org.gnome.desktop.input-sources xkb-options "['"'"'grp:alt_shift_toggle'"'"']"
' 2>/dev/null || log "gsettings pre-seed skipped (runs on first login anyway)"

# ------------------------------------------------------------
# 6. Steam / Discord / Chrome / VS Code  (each non-fatal)
# ------------------------------------------------------------
app() { set +e; "$@"; set -e; }

if [ "$INSTALL_STEAM" = 1 ]; then
  log "steam"
  add-apt-repository -y multiverse || true
  apt-get update
  echo "steam steam/question select 'I AGREE'" | debconf-set-selections
  echo "steam steam/license note ''" | debconf-set-selections
  app apt-get install -y steam-installer
fi

if [ "$INSTALL_DISCORD" = 1 ]; then
  log "discord"
  for i in 1 2 3 4 5; do curl -4 -fL --retry 3 -o /root/discord.deb "https://discord.com/api/download?platform=linux&format=deb" && break || sleep 6; done
  [ -s /root/discord.deb ] && app apt-get install -y /root/discord.deb || log "discord skipped"
fi

install -d -m 0755 /etc/apt/keyrings
if [ "$INSTALL_CHROME" = 1 ]; then
  log "chrome"
  curl -4 -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list
  apt-get update -qq && app apt-get install -y google-chrome-stable || log "chrome skipped"
fi

if [ "$INSTALL_VSCODE" = 1 ]; then
  log "vscode"
  curl -4 -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" >/etc/apt/sources.list.d/vscode.list
  apt-get update -qq && app apt-get install -y code || log "vscode skipped"
fi

# ------------------------------------------------------------
# 7. sanity
# ------------------------------------------------------------
echo ""
echo "=== checks ==="
ls -l /dev/dri/card0 /dev/nvidia0 /dev/fb0 2>&1 || echo "!! seat nodes missing — re-run lxc-ct-passthrough.sh, restart CT"
nvidia-smi -L 2>&1 || echo "!! nvidia-smi failed (host/CT driver mismatch?)"
loginctl seat-status seat0 2>&1 | grep -q 'drm:card0' && echo "seat0 has drm:card0 (Wayland can take master)" || echo "!! seat0 has no DRM — check lxc.mount.auto sys:rw + workstation-coldplug"
echo "gnome-shell: $(dpkg -query -W -f='${Version}' gnome-shell 2>/dev/null || echo MISSING)"
echo "gdm autologin: $(grep -c AutomaticLogin=${SEAT_USER} /etc/gdm3/custom.conf)"
echo "installed apps: $(dpkg -l steam-installer discord google-chrome-stable code 2>/dev/null | grep -c '^ii') / 4"
echo ""
echo "Reboot the CT:  pct reboot <ctid>   (or  workstation.sh start ubuntu  from stopped)"
echo "GDM autologs '${SEAT_USER}' into a GNOME/Wayland session on the monitors."
echo "journalctl -b -u gdm ; journalctl -b _COMM=gnome-shell ; ~${SEAT_USER}/.local/share/xorg is X11-only (unused)"
