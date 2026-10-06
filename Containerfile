# =============================================================================
# bootc-fedora-gnome-macbookair
# Immutable Fedora 44 + GNOME Shell image tailored for MacBook Air hardware.
# Includes Broadcom WiFi, FaceTimeHD camera, and MacBook-specific optimizations.
# =============================================================================

# ── Stage 1: Build out-of-tree kernel modules ──────────────────────────────
# Build Broadcom WiFi (akmod-wl) and FaceTimeHD camera (akmod-facetimehd)
# in an isolated builder so build-only deps don't pollute the final image.
ARG BASE_IMAGE=quay.io/fedora/fedora-bootc
ARG FEDORA_VERSION=44

FROM ${BASE_IMAGE}:${FEDORA_VERSION} AS builder

RUN <<BUILDER
set -euo pipefail

# Build against the kernel shipped in the base image: the final stage keeps
# that same kernel, so the modules must match it exactly.
KERNEL_VERSION="$(ls /usr/lib/modules)"
FEDORA_RELEASE="$(rpm -E '%fedora')"
echo "▸ Detected kernel: ${KERNEL_VERSION}  (Fedora ${FEDORA_RELEASE})"

echo "▸ Installing matching kernel-devel"
if ! dnf5 -y install "kernel-devel-${KERNEL_VERSION}" --refresh; then
    # The updates repo may already be ahead of the base image kernel
    echo "▸ kernel-devel-${KERNEL_VERSION} not in repos, fetching from Koji"
    KOJI_PATH="$(rpm -q kernel-core --queryformat '%{VERSION}/%{RELEASE}/%{ARCH}')"
    dnf5 -y install "https://kojipkgs.fedoraproject.org/packages/kernel/${KOJI_PATH}/kernel-devel-${KERNEL_VERSION}.rpm"
fi

echo "▸ Installing build tools"
dnf5 -y install akmods git make gcc

# ── Broadcom WiFi (from RPMFusion Non-Free) ──
echo "▸ Enabling RPMFusion Non-Free repository"
dnf5 -y install \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

echo "▸ Installing and building akmod-wl (Broadcom WiFi)"
dnf5 -y install akmod-wl
akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# ── FaceTimeHD camera (kmod built from patjak/facetimehd source) ──
# The COPR is kept only for the facetimehd-kmod-common userspace package;
# the kernel module itself is compiled from upstream source below.
echo "▸ Enabling COPR for facetimehd-kmod-common"
curl -LsSf -o /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo \
    "https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-${FEDORA_RELEASE}/mulderje-facetimehd-kmod-fedora-${FEDORA_RELEASE}.repo"

echo "▸ Building FaceTimeHD kmod from source (patjak/facetimehd)"
git clone --depth 1 https://github.com/patjak/facetimehd.git /tmp/facetimehd
make -C /usr/src/kernels/${KERNEL_VERSION} M=/tmp/facetimehd modules

# Cleanup builder cache for this layer
dnf5 clean all && rm -rf /var/cache/libdnf5 /var/lib/dnf

# ── Build FaceTimeHD firmware ──
echo "▸ Building FaceTimeHD firmware from source"
git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware
cd /tmp/facetimehd-firmware && make && make install
BUILDER

# ── Stage 2: Final bootable image ──────────────────────────────────────────
FROM ${BASE_IMAGE}:${FEDORA_VERSION}

LABEL org.opencontainers.image.title="bootc-fedora-gnome-macbookair" \
      org.opencontainers.image.description="Immutable Fedora + GNOME bootc image for Intel MacBook Air" \
      org.opencontainers.image.source="https://github.com/CleoMenezesJr/bootc-fedora-gnome-macbookair"

# Copy pre-built kernel module RPMs from builder
COPY --from=builder /var/cache/akmods/wl/kmod-wl*.rpm /tmp/kmods/
# FaceTimeHD module compiled from patjak/facetimehd source
COPY --from=builder /tmp/facetimehd/facetimehd.ko /tmp/facetimehd.ko

# Copy FaceTimeHD firmware and repo config from builder
COPY --from=builder /usr/lib/firmware/facetimehd/ /usr/lib/firmware/facetimehd/
COPY --from=builder /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo /etc/yum.repos.d/

# Copy project configuration files directly to their final destinations
# ── Packages list ──
COPY packages.rpm /tmp/packages.rpm
# ── First-login Flatpak bootstrap (runs as user service) ──
COPY --chmod=755 post-install.sh /usr/bin/post-install.sh
COPY post-install.service /usr/lib/systemd/user/post-install.service
# ── MacBook keyboard: fn key behavior, swap alt/cmd ──
COPY hid-apple.conf /usr/lib/modprobe.d/hid-apple.conf
# ── Dracut: optimized initramfs (consolidates facetimehd + no-nfs) ──
COPY dracut-optimize.conf /usr/lib/dracut/dracut.conf.d/50-macbook-optimize.conf
# ── Kernel modules: ensure coretemp + applesmc loaded at boot ──
COPY modules-load.conf /usr/lib/modules-load.d/macbook.conf
# ── Audio power save: Intel HDA codec off when idle ──
COPY audio-power-save.conf /usr/lib/modprobe.d/audio-power-save.conf
# ── Udev: user-writable screen + keyboard backlight ──
COPY 90-backlight.rules /usr/lib/udev/rules.d/90-backlight.rules
COPY 91-leds.rules /usr/lib/udev/rules.d/91-leds.rules
# ── Udev: exclude bcm5974 trackpad from USB autosuspend ──
COPY 92-trackpad-autosuspend.rules /usr/lib/udev/rules.d/92-trackpad-autosuspend.rules
# ── Udev: prevent Thunderbolt switch from entering D3cold ──
COPY 94-thunderbolt-pm.rules /usr/lib/udev/rules.d/94-thunderbolt-pm.rules
# ── Suspend: disable spurious wakeup sources (XHC1, EHC1, EHC2) ──
COPY suspend-fix.service /usr/lib/systemd/system/suspend-fix.service
# ── Suspend: Broadcom wl WiFi interface reset ──
COPY --chmod=755 wl-suspend.sh /usr/bin/wl-suspend.sh
COPY wl-suspend.service /usr/lib/systemd/system/wl-suspend.service
# ── Suspend: stop heavy services before sleep for fast resume ──
COPY --chmod=755 sleep-helpers.sh /usr/bin/sleep-helpers.sh
COPY sleep-helpers.service /usr/lib/systemd/system/sleep-helpers.service
# ── Resume: restart macbook-lighter after user.slice is thawed ──
COPY --chmod=755 resume-lighter.sh /usr/bin/resume-lighter.sh
COPY resume-lighter.service /usr/lib/systemd/system/resume-lighter.service
# ── Suspend-then-hibernate: S3 first, hibernate after 60min ──
COPY sleep.conf /usr/lib/systemd/sleep.conf.d/macbook.conf
COPY logind.conf /usr/lib/systemd/logind.conf.d/macbook.conf
# ── Lid wakeup guard: re-suspend if lid is still closed ──
COPY --chmod=755 lid-wakeup-guard.sh /usr/bin/lid-wakeup-guard.sh
COPY lid-wakeup-guard.service /usr/lib/systemd/system/lid-wakeup-guard.service
# ── Udev: re-enable LID0 wakeup when lid opens ──
COPY 93-lid-wakeup.rules /usr/lib/udev/rules.d/93-lid-wakeup.rules
# ── Fan control: custom mbpfan curve for A1466 ──
COPY mbpfan.conf /etc/mbpfan.conf
# ── Power management: tuned custom profile ──
COPY tuned-macbook-profile/tuned.conf /usr/lib/tuned/profiles/macbook-profile/tuned.conf

# ── System configuration & kernel module installation ──
RUN <<SYSCONFIG
set -euo pipefail

echo "▸ Creating required directories"
mkdir -vp /var/roothome /data /var/home
mkdir -vp /usr/lib/systemd/sleep.conf.d /usr/lib/systemd/logind.conf.d

# Pin kernel-modules-extra to the image kernel: an unpinned install pulls the
# newest kernel-core too, leaving two kernels in the image.
kver="$(ls /usr/lib/modules)"
echo "▸ Installing kernel-modules-extra-${kver}"
if ! dnf5 -y install "kernel-modules-extra-${kver}" --refresh; then
    KOJI_PATH="$(rpm -q kernel-core --queryformat '%{VERSION}/%{RELEASE}/%{ARCH}')"
    dnf5 -y install "https://kojipkgs.fedoraproject.org/packages/kernel/${KOJI_PATH}/kernel-modules-extra-${kver}.rpm"
fi

# ── Kernel Arguments: ACPI OSI hacks for MacBook hardware ──
# Declaring kernel arguments via bootc-native configuration files.
mkdir -p /usr/lib/bootc/kargs.d/
cat > /usr/lib/bootc/kargs.d/10-macbook.toml <<'KARGS'
kargs = ["acpi_osi=!Darwin", "acpi_osi=!Windows 2012"]
match-architectures = ["x86_64"]
KARGS

# ── Kernel Arguments: Intel GPU + PCIe power savings (MacBookAir7,2 / Broadwell) ──
# PSR: Panel Self Refresh — cuts eDP link power when framebuffer is static
# DC: Display power states (DC5/DC6 deepest)
# FBC: Frame Buffer Compression — compresses framebuffer in VRAM
# GuC/HuC: GPU firmware for power management + VA-API
# pcie_aspm=active: enables ASPM only on devices that support it
cat > /usr/lib/bootc/kargs.d/20-macbook-power.toml <<'KARGS'
kargs = [
  "i915.enable_psr=1",
  "i915.enable_dc=2",
  "i915.enable_fbc=1",
  "i915.enable_guc=2",
  "pcie_aspm=active",
  "mem_sleep_default=deep"
]
match-architectures = ["x86_64"]
KARGS

# ── Kernel Arguments: NVMe + USB power savings ──
# NVMe PS3 allowed (~55ms resume) but not PS4 (causes hangs on some MacBook SSDs)
# USB autosuspend after 5s (bcm5974 trackpad excluded via udev rule)
cat > /usr/lib/bootc/kargs.d/30-macbook-hardware.toml <<'KARGS'
kargs = [
  "nvme_core.default_ps_max_latency_us=55000",
  "usbcore.autosuspend=5"
]
match-architectures = ["x86_64"]
KARGS

# ── Restore screen backlight after S3 resume ──
# After S3 resume the intel_backlight driver may leave brightness at 0.
# This hook saves the brightness before sleep and restores it after wake.
mkdir -p /usr/lib/systemd/system-sleep
cat > /usr/lib/systemd/system-sleep/restore-backlight.sh <<'HOOK'
#!/bin/bash
BACKLIGHT=/sys/class/backlight/intel_backlight
case "$1" in
    pre)
        cat "$BACKLIGHT/brightness" > /tmp/backlight-brightness 2>/dev/null || true
        ;;
 post)
 sleep 1
 if [ -f /tmp/backlight-brightness ]; then
 cat /tmp/backlight-brightness > "$BACKLIGHT/brightness" 2>/dev/null || true
 fi
 # NOTE: Do NOT call systemctl --user or sudo -u here.
 # This hook runs inside the systemd-suspend cgroup while user.slice
 # is still frozen. Calling systemctl --user blocks until user.slice
 # thaws, but user.slice will not thaw until systemd-suspend finishes,
 # creating a deadlock that adds ~45s to resume time.
 # macbook-lighter restart is handled by resume-lighter.service instead.
        ;;
esac
HOOK
chmod +x /usr/lib/systemd/system-sleep/restore-backlight.sh

# ── RPMFusion for broadcom-wl runtime dependencies ──
FEDORA_RELEASE="$(rpm -E '%fedora')"
dnf5 -y install \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# ── Install pre-built kernel modules ──
echo "▸ Installing Broadcom WiFi kernel module (kmod-wl)"
dnf5 -y install /tmp/kmods/kmod-wl-*.rpm

echo "▸ Installing FaceTimeHD camera kernel module (built from patjak/facetimehd)"
dnf5 -y install facetimehd-kmod-common
install -D /tmp/facetimehd.ko \
    /usr/lib/modules/${kver}/extra/facetimehd/facetimehd.ko
depmod -a "${kver}"
rm -f /tmp/facetimehd.ko

# Fail the build early if the modules don't match the image kernel
for mod in wl facetimehd; do
    modinfo -k "${kver}" "${mod}" >/dev/null || {
        echo "✗ Module ${mod} not available for kernel ${kver}" >&2
        exit 1
    }
done

# ── Initramfs: regenerated after modules, firmware and modprobe.d are in place ──
echo "▸ Regenerating initramfs for ${kver}"
DRACUT_NO_XATTR=1 dracut -vf "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

# ── Writable directories (bootc best practice) ──
# See: https://bootc-dev.github.io/bootc/building/guidance.html
# Symlinks must be relative: `bootc container lint` resolves them inside the
# image root and fails on absolute targets (runtime-deps lint).
echo "▸ Setting up writable /opt and /usr/local"
rm -rvf /opt && mkdir -vp /var/opt && ln -vs var/opt /opt
mkdir -vp /var/usrlocal && mv -v /usr/local/* /var/usrlocal/ 2>/dev/null || true
rm -rvf /usr/local && ln -vs ../var/usrlocal /usr/local

# ── Persistent journal ──
mkdir -p /usr/lib/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' > /usr/lib/systemd/journald.conf.d/persistent.conf

# ── Timezone: Santiago, Chile ──
echo "▸ Setting timezone to America/Santiago"
ln -sf /usr/share/zoneinfo/America/Santiago /etc/localtime

# ── Keyboard layout: Spanish (Latin American / MacBook) ──
echo "▸ Configuring keyboard layout (latam, apple_laptop)"
cat > /etc/vconsole.conf <<'VCONSOLE'
KEYMAP=latam
VCONSOLE

# ── Cleanup builder artifacts ──
echo "▸ Cleaning up build artifacts and fixing bootc lint issues"
rm -rvf /tmp/kmods
# Force remove /usr/etc if any build process created it
rm -rvf /usr/etc
# Clear /boot as it's populated at runtime by bootc
rm -rvf /boot/*
dnf5 clean all
rm -rfv /var/cache/* \
        /var/log/* \
        /var/tmp/* \
        /var/lib/dnf/* \
        /var/cache/libdnf5/*
SYSCONFIG

# ── Stage 2.1: Install GNOME Shell (minimal, no weak deps) ──────────────────
RUN echo "▸ Installing GNOME Shell (minimal)" && \
    dnf5 install gnome-shell -y && \
    dnf5 clean all && \
    rm -rfv /var/cache/* \
    /var/log/* \
    /var/tmp/* \
    /var/cache/libdnf5/* /var/lib/dnf/*

# ── Stage 2.2: Install RPM packages from list & configure services ──────────
RUN <<PACKAGES
set -euo pipefail

echo "▸ Installing RPM packages from packages.rpm"
dnf5 -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
# Remove rawhide repos to prevent fc45 packages being pulled on Fedora 44
find /etc/yum.repos.d/ -name '*rawhide*' -delete
grep -v '^\s*#' /tmp/packages.rpm | grep -v '^\s*$' | xargs dnf5 install -y --refresh
dnf5 remove -y gnome-tour

# ── Install macbook-lighter from source ──
echo "▸ Installing macbook-lighter from source"
git clone --depth 1 https://github.com/CleoMenezesJr/macbook-lighter.git /tmp/macbook-lighter
cd /tmp/macbook-lighter
make install DESTDIR=/
sed -i 's/^ML_DEBUG=false/ML_DEBUG=true/' /etc/macbook-lighter.conf
cd / && rm -rf /tmp/macbook-lighter

# ── Install weather-oclock GNOME extension ──
echo "▸ Installing weather-oclock GNOME extension from source"
git clone --depth 1 https://github.com/CleoMenezesJr/weather-oclock.git /tmp/weather-oclock
cd /tmp/weather-oclock
make install DESTDIR=/
cd / && rm -rf /tmp/weather-oclock

# ── Install mbpfan v2.4.0 from source (missing in Fedora 44 repos) ──
echo "▸ Installing mbpfan v2.4.0 from source"
git clone --depth 1 --branch v2.4.0 https://github.com/linux-on-mac/mbpfan.git /tmp/mbpfan
cd /tmp/mbpfan
make
make install
# Ensure service file is in the correct systemd directory
cp -v mbpfan.service /usr/lib/systemd/system/mbpfan.service
cd /
rm -rf /tmp/mbpfan

# ── tuned-ppd: map GNOME's "Balanced" mode (AC and battery) to macbook-profile ──
sed -i 's/^balanced=balanced\(-battery\)\?$/balanced=macbook-profile/' /etc/tuned/ppd.conf
grep -c '^balanced=macbook-profile$' /etc/tuned/ppd.conf | grep -qx 2

# ── GNOME system defaults via dconf ──
echo "▸ Configuring GNOME system defaults"
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/profile/user <<'DCONF_PROFILE'
user-db:user
system-db:local
DCONF_PROFILE
cat > /etc/dconf/db/local.d/00-gnome-extensions <<'DCONF_EXTENSIONS'
[org/gnome/shell]
enabled-extensions=['weatheroclock@CleoMenezesJr.github.io', 'macbook-lighter@cleomenezesjr.github.io']
DCONF_EXTENSIONS
cat > /etc/dconf/db/local.d/02-keyboard <<'DCONF_KEYBOARD'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'latam')]
xkb-options=['apple:alupckeys']
DCONF_KEYBOARD
# Disable GNOME Software automatic updates + reboot to prevent unexpected reboots.
# Updates are managed manually via: sudo bootc upgrade && sudo reboot
cat > /etc/dconf/db/local.d/01-gnome-software <<'DCONF_SOFTWARE'
[org/gnome/software]
download-updates=false
apply-updates=false
DCONF_SOFTWARE
# Mutter experimental features: KMS modifiers for better i915 performance,
# autoclose Xwayland when no X11 apps, per-monitor fractional scaling
cat > /etc/dconf/db/local.d/03-mutter <<'DCONF_MUTTER'
[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer', 'kms-modifiers', 'autoclose-xwayland']
DCONF_MUTTER
# Font rendering: RGBA subpixel for non-Retina 1366x768 display
cat > /etc/dconf/db/local.d/04-fonts <<'DCONF_FONTS'
[org/gnome/desktop/interface]
font-antialiasing='rgba'
font-hinting='slight'
font-rgba-order='rgb'
DCONF_FONTS
# Power saving: idle dim, suspend-then-hibernate on battery, power-saver on low battery
cat > /etc/dconf/db/local.d/05-power <<'DCONF_POWER'
[org/gnome/settings-daemon/plugins/power]
idle-dim=true
idle-brightness=20
sleep-inactive-battery-timeout=600
sleep-inactive-battery-type='suspend-then-hibernate'
power-saver-profile-on-low-battery=true

[org/gnome/desktop/session]
idle-delay=120
DCONF_POWER
# Night Light: 3500K warmth with automatic schedule
cat > /etc/dconf/db/local.d/06-nightlight <<'DCONF_NIGHTLIGHT'
[org/gnome/settings-daemon/plugins/color]
night-light-enabled=true
night-light-temperature=uint32 3500
night-light-schedule-automatic=true
DCONF_NIGHTLIGHT
# Responsiveness: faster unresponsive app detection (3s instead of 5s)
cat > /etc/dconf/db/local.d/07-responsiveness <<'DCONF_RESPONSIVE'
[org/gnome/mutter]
check-alive-timeout=uint32 3000

[org/gnome/desktop/interface]
enable-animations=true
overlay-scrolling=true
DCONF_RESPONSIVE
dconf update

# ── Configuring systemd services ──
echo "▸ Configuring systemd services"
# Mask unnecessary services
# systemd-remount-fs: bootc manages root mount options via initrd, not fstab
# rpc-gssd: NFS GSS security daemon, not needed on a desktop MacBook
# bootc-fetch-apply-updates.timer: prevents unexpected automatic reboots (updates managed manually)
# tracker-miner-fs/extract: indexer I/O not worth the benefit on lightweight desktop
systemctl mask \
 systemd-remount-fs.service \
 rpc-gssd.service \
 chronyd.service \
 bootc-fetch-apply-updates.timer \
 tracker-miner-fs-3.service \
 tracker-extract-3.service

# Enable system-wide hardware services
# powertop.service removed — replaced by tuned custom profile
systemctl enable \
 mbpfan.service \
 tuned.service \
 tuned-ppd.service \
 suspend-fix.service \
 wl-suspend.service \
 sleep-helpers.service \
 lid-wakeup-guard.service \
 resume-lighter.service

# ── PAM: disable fingerprint auth when fprintd-pam is not installed ──
# The base image ships authselect profile "local" with "with-fingerprint"
# but fprintd-pam is not installed, causing PAM warnings on every sudo.
authselect select local with-silent-lastlog with-mdns4 --force --nobackup

# Enable user-level bootstrap services globally for all graphical sessions
systemctl --global enable \
    macbook-lighter.service \
    post-install.service


# ── FacetimeHD: silence optional firmware load error ──
# The facetimehd module loads firmware.bin successfully but also tries
# to load 1871_01XX.dat (an optional calibration file). Since that file
# doesn't exist, the kernel logs an error each boot and on S3 resume.
# Create a symlink so the kernel finds the file and doesn't log the error.
ln -sf firmware.bin /usr/lib/firmware/facetimehd/1871_01XX.dat

# ── Final cleanup ──
echo "▸ Final cleanup for bootc compliance"
rm -f /tmp/packages.rpm
dnf5 clean all
rm -rfv /var/cache/* \
        /var/log/* \
        /var/tmp/* \
        /var/cache/libdnf5/* \
        /var/lib/dnf \
        /var/usrlocal/share/applications/mimeinfo.cache \
        /var/roothome/.*
# Final check for /usr/etc
rm -rvf /usr/etc

# ── Declare /var dirs for bootc lint compliance ──
echo "▸ Declaring tmpfiles.d entries for /var dirs"
cat > /usr/lib/tmpfiles.d/bootc-var-dirs.conf <<'TMPFILES'
d /var/roothome 0750 - - -
d /var/data 0755 - - -
d /var/opt 0755 - - -
d /var/usrlocal 0755 - - -
d /var/cache 0755 - - -
d /var/log 0755 - - -
d /var/tmp 1777 - - -
d /var/lib 0755 - - -
d /var/lib/dnf 0755 - - -
TMPFILES
PACKAGES

# ── Lint the final image ──
RUN bootc container lint
