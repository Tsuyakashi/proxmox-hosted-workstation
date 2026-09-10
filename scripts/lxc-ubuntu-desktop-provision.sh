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
apt-get install -y curl wget ca-certificates gnupg software-properties-common \
  openssl libinput-tools wayland-utils mesa-utils vulkan-tools libsecret-tools
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
systemctl enable gdm 2>/dev/null || true
# display-manager.service -> gdm3.service symlink is what actually starts GDM
# at graphical.target; make sure it exists.
[ -e /etc/systemd/system/display-manager.service ] || \
  ln -sf /usr/lib/systemd/system/gdm3.service /etc/systemd/system/display-manager.service

# container noise: these units always fail in an LXC and only serve to make
# `systemctl is-system-running` report "degraded".
systemctl mask apparmor.service tpm-udev.path tpm-udev.service \
  console-getty.service systemd-rfkill.socket systemd-rfkill.service 2>/dev/null || true

# ------------------------------------------------------------
# 4. coldplug udev at boot (bind-mounted nodes fire no uevents)
# ------------------------------------------------------------
# The GPU/USB/input nodes are bind-mounted in by LXC and fire no uevents
# inside the CT, so systemd-udevd's DB starts empty -> libinput sees nothing
# and logind's seat0 has no DRM. A coldplug re-trigger (writable /sys, from
# lxc-ct-passthrough.sh) fixes both. Also mark card0 master-of-seat.
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
# 5. GNOME defaults (system dconf) + monitor layout + keyring
# ------------------------------------------------------------
install -d -o "$SEAT_USER" -g "$SEAT_USER" "${SEAT_HOME}/.config"
# user is pre-created here, not by gnome-initial-setup — skip its wizard
sudo -u "$SEAT_USER" touch "${SEAT_HOME}/.config/gnome-initial-setup-done"
apt-get purge -y gnome-initial-setup 2>/dev/null || true

# System-wide GNOME defaults via dconf (no live session needed, unlike gsettings)
install -d /etc/dconf/profile /etc/dconf/db/local.d
cat >/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
cat >/etc/dconf/db/local.d/00-workstation <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'

[org/gnome/desktop/screensaver]
lock-enabled=false

[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('xkb', 'ru')]
xkb-options=['grp:alt_shift_toggle']
EOF
dconf update || log "dconf update failed (non-fatal)"

# Monitor layout: AOC 144Hz on HDMI-1 (left, primary), Philips 60Hz on
# DVI-I-1 (right). GNOME matches on connector+vendor+product+serial; the
# product/serial below are THIS rig's EDID. If they differ, GNOME ignores
# this file and falls back to its own default — just fix it once in
# Settings -> Displays, which persists back here.
write_monitors() {
  cat > "$1" <<'EOF'
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x><y>0</y><scale>1</scale><primary>yes</primary>
      <monitor><monitorspec>
        <connector>HDMI-1</connector><vendor>AOC</vendor><product>2590G4</product><serial>0x00015024</serial>
      </monitorspec><mode><width>1920</width><height>1080</height><rate>144.00076293945312</rate></mode></monitor>
    </logicalmonitor>
    <logicalmonitor>
      <x>1920</x><y>0</y><scale>1</scale>
      <monitor><monitorspec>
        <connector>DVI-I-1</connector><vendor>PHL</vendor><product>PHL 246E9Q</product><serial>UK02043000888</serial>
      </monitorspec><mode><width>1920</width><height>1080</height><rate>60.000</rate></mode></monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF
}
write_monitors "${SEAT_HOME}/.config/monitors.xml"
chown "$SEAT_USER:$SEAT_USER" "${SEAT_HOME}/.config/monitors.xml"
install -d -o gdm -g gdm /var/lib/gdm3/.config 2>/dev/null || true
write_monitors /var/lib/gdm3/.config/monitors.xml 2>/dev/null || true
chown -R gdm:gdm /var/lib/gdm3/.config 2>/dev/null || true

# Autologin can't unlock the login keyring (no password prompt). Pre-create
# an UNENCRYPTED default keyring so libsecret apps (Chrome, grdctl) don't nag
# and can actually store secrets.
install -d -o "$SEAT_USER" -g "$SEAT_USER" -m 700 "${SEAT_HOME}/.local/share/keyrings"
cat >"${SEAT_HOME}/.local/share/keyrings/Default_keyring.keyring" <<'EOF'
[keyring]
display-name=Default keyring
lock-on-idle=false
lock-after=false
EOF
printf 'Default_keyring' >"${SEAT_HOME}/.local/share/keyrings/default"
chown -R "$SEAT_USER:$SEAT_USER" "${SEAT_HOME}/.local/share/keyrings"

# ------------------------------------------------------------
# 5b. gnome-remote-desktop: RDP into the live session (morning/away access)
# ------------------------------------------------------------
apt-get install -y gnome-remote-desktop 2>/dev/null || true
GRD_DIR="${SEAT_HOME}/.config/gnome-remote-desktop"
install -d -o "$SEAT_USER" -g "$SEAT_USER" -m 700 "$GRD_DIR"
if [ ! -s "${GRD_DIR}/rdp-tls.key" ]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${GRD_DIR}/rdp-tls.key" -out "${GRD_DIR}/rdp-tls.crt" \
    -subj "/CN=${SEAT_USER}-workstation" >/dev/null 2>&1
fi
chown "$SEAT_USER:$SEAT_USER" "${GRD_DIR}"/rdp-tls.*
chmod 600 "${GRD_DIR}/rdp-tls.key"; chmod 644 "${GRD_DIR}/rdp-tls.crt"
systemctl --global disable gnome-remote-desktop.service 2>/dev/null || true
systemctl disable gnome-remote-desktop.service 2>/dev/null || true  # system unit off; we share the live session
# The actual `grdctl rdp enable` + credentials need a live user D-Bus session,
# so they run from the per-login user unit below.
install -d "${SEAT_HOME}/.config/systemd/user"
cat >"${SEAT_HOME}/.config/systemd/user/workstation-rdp.service" <<EOF
[Unit]
Description=Enable gnome-remote-desktop RDP for this session
After=graphical-session.target gnome-remote-desktop.service
PartOf=graphical-session.target
[Service]
Type=oneshot
ExecStart=/usr/bin/grdctl rdp set-tls-cert %h/.config/gnome-remote-desktop/rdp-tls.crt
ExecStart=/usr/bin/grdctl rdp set-tls-key %h/.config/gnome-remote-desktop/rdp-tls.key
ExecStart=/usr/bin/grdctl rdp set-credentials ${SEAT_USER} ${SEAT_PASSWORD}
ExecStart=/usr/bin/grdctl rdp disable-view-only
ExecStart=/usr/bin/grdctl rdp enable
ExecStart=/usr/bin/systemctl --user restart gnome-remote-desktop.service
RemainAfterExit=yes
[Install]
WantedBy=graphical-session.target
EOF
chown -R "$SEAT_USER:$SEAT_USER" "${SEAT_HOME}/.config/systemd"
sudo -u "$SEAT_USER" XDG_RUNTIME_DIR="/run/user/${SEAT_UID}" \
  systemctl --user enable workstation-rdp.service 2>/dev/null || \
  ln -sf ../workstation-rdp.service \
    "${SEAT_HOME}/.config/systemd/user/graphical-session.target.wants/workstation-rdp.service" 2>/dev/null || \
  { install -d "${SEAT_HOME}/.config/systemd/user/graphical-session.target.wants"; \
    ln -sf ../workstation-rdp.service \
    "${SEAT_HOME}/.config/systemd/user/graphical-session.target.wants/workstation-rdp.service"; }
chown -R "$SEAT_USER:$SEAT_USER" "${SEAT_HOME}/.config/systemd"

# ------------------------------------------------------------
# 6. Steam / Discord / Chrome / VS Code  (each non-fatal)
# ------------------------------------------------------------
app() { set +e; "$@"; set -e; }

if [ "$INSTALL_STEAM" = 1 ] && ! dpkg -l steam-installer 2>/dev/null | grep -q '^ii'; then
  log "steam"
  add-apt-repository -y multiverse || true
  apt-get update
  echo "steam steam/question select 'I AGREE'" | debconf-set-selections
  echo "steam steam/license note ''" | debconf-set-selections
  app apt-get install -y steam-installer
fi

if [ "$INSTALL_DISCORD" = 1 ] && ! dpkg -l discord 2>/dev/null | grep -q '^ii'; then
  log "discord"
  for i in 1 2 3 4 5; do curl -4 -fL --retry 3 -o /root/discord.deb "https://discord.com/api/download?platform=linux&format=deb" && break || sleep 6; done
  [ -s /root/discord.deb ] && app apt-get install -y /root/discord.deb || log "discord skipped"
fi

install -d -m 0755 /etc/apt/keyrings
addkey() { curl -4 -fsSL "$2" | gpg --batch --yes --dearmor -o "$1"; }
if [ "$INSTALL_CHROME" = 1 ] && ! command -v google-chrome >/dev/null; then
  log "chrome"
  app addkey /etc/apt/keyrings/google-chrome.gpg https://dl.google.com/linux/linux_signing_key.pub
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list
  apt-get update -qq && app apt-get install -y google-chrome-stable || log "chrome skipped"
fi

if [ "$INSTALL_VSCODE" = 1 ] && ! command -v code >/dev/null; then
  log "vscode"
  app addkey /etc/apt/keyrings/microsoft.gpg https://packages.microsoft.com/keys/microsoft.asc
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
findmnt -no OPTIONS /sys | grep -q '^rw' && echo "/sys is rw (udev ok)" || echo "!! /sys is ro — add lxc.mount.auto sys:rw (lxc-ct-passthrough.sh)"
loginctl seat-status seat0 2>&1 | grep -q 'drm:card0' && echo "seat0 has drm:card0 (Wayland can take master)" || echo "!! seat0 has no DRM — check /sys rw + workstation-coldplug"
echo "gnome-shell: $(dpkg-query -W -f='${Version}' gnome-shell 2>/dev/null || echo MISSING)"
echo "gdm autologin: $(grep -c "AutomaticLogin=${SEAT_USER}" /etc/gdm3/custom.conf)"
echo "wayland session: $(ls /usr/share/wayland-sessions/ 2>/dev/null | tr '\n' ' ')"
echo "installed apps: $(dpkg -l steam-installer discord google-chrome-stable code 2>/dev/null | grep -c '^ii') / 4"
echo ""
echo "Reboot the CT:  pct reboot <ctid>   (or  workstation.sh start ubuntu  from stopped)"
echo "GDM autologs '${SEAT_USER}' into a GNOME 50 / Wayland session on the monitors."
echo "Remote:  xfreerdp3 /v:<ct-ip> /u:${SEAT_USER} /p:<pw> /cert:ignore   (g-r-d RDP :3389, NVENC)"
echo "Logs:    journalctl -b -u gdm ; journalctl -b _COMM=gnome-shell"
