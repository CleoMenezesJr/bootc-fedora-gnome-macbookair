# =============================================================================
# bootc-fedora-gnome-macbookair
# Immutable Fedora 44 + GNOME Shell image tailored for MacBook Air hardware.
# Includes Broadcom WiFi, FaceTimeHD camera, and MacBook-specific optimizations.
# =============================================================================

# ── Stage 1: Build out-of-tree kernel modules ──────────────────────────────
# Build Broadcom WiFi (akmod-wl) and FaceTimeHD camera (akmod-facetimehd)
# in an isolated builder so build-only deps don't pollute the final image.
FROM quay.io/fedora/fedora-bootc:44 AS builder

RUN <<BUILDER
set -euo pipefail

echo "▸ Upgrading kernel packages"
dnf5 upgrade -y 'kernel*' --refresh

echo "▸ Installing kernel-devel and build tools"
dnf5 -y install kernel-devel akmods wget git make gcc --refresh

KERNEL_VERSION="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
FEDORA_RELEASE="$(rpm -E '%fedora')"
echo "▸ Detected kernel: ${KERNEL_VERSION}  (Fedora ${FEDORA_RELEASE})"

# ── Broadcom WiFi (from RPMFusion Non-Free) ──
echo "▸ Enabling RPMFusion Non-Free repository"
dnf5 -y install \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

echo "▸ Installing and building akmod-wl (Broadcom WiFi)"
dnf5 -y install akmod-wl
akmods --force --kernels "${KERNEL_VERSION}" --kmod wl

# ── FaceTimeHD camera (from COPR mulderje/facetimehd-kmod) ──
echo "▸ Enabling COPR for FaceTimeHD kernel module"
# For Fedora >= 41 the COPR uses "rawhide" as the release identifier
if [ "${FEDORA_RELEASE}" -ge 41 ]; then
    COPR_RELEASE="rawhide"
else
    COPR_RELEASE="${FEDORA_RELEASE}"
fi
curl -LsSf -o /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo \
    "https://copr.fedorainfracloud.org/coprs/mulderje/facetimehd-kmod/repo/fedora-${COPR_RELEASE}/mulderje-facetimehd-kmod-fedora-${COPR_RELEASE}.repo"

echo "▸ Installing and building akmod-facetimehd"
ARCH="$(rpm -E '%_arch')"
dnf5 -y install "akmod-facetimehd-*.fc${FEDORA_RELEASE}.${ARCH}" || \
    dnf5 -y install akmod-facetimehd facetimehd-kmod-common
akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd

# Cleanup builder cache for this layer
dnf5 clean all && rm -rf /var/cache/libdnf5 /var/lib/dnf

# ── Build FaceTimeHD firmware ──
echo "▸ Building FaceTimeHD firmware from source"
git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware
cd /tmp/facetimehd-firmware && make && make install
BUILDER

# ── Stage 2: Final bootable image ──────────────────────────────────────────
FROM quay.io/fedora/fedora-bootc:44

# Copy pre-built kernel module RPMs from builder
COPY --from=builder /var/cache/akmods/wl/kmod-wl*.rpm /tmp/kmods/
COPY --from=builder /var/cache/akmods/facetimehd/kmod-facetimehd*.rpm /tmp/kmods/

# Copy FaceTimeHD firmware and repo config from builder
COPY --from=builder /usr/lib/firmware/facetimehd/ /usr/lib/firmware/facetimehd/
COPY --from=builder /etc/yum.repos.d/_copr_mulderje-facetimehd-kmod.repo /etc/yum.repos.d/

# Copy project configuration files directly to their final destinations
COPY packages.rpm /tmp/packages.rpm
# First-login Flatpak bootstrap (runs as user service)
COPY --chmod=755 post-install.sh /usr/bin/post-install.sh
# Triggers post-install.sh on first graphical login
COPY post-install.service /usr/lib/systemd/user/post-install.service
# MacBook keyboard: fn key behavior, swap alt/cmd
COPY hid-apple.conf /etc/modprobe.d/hid-apple.conf
# Include FaceTimeHD firmware in initramfs
COPY dracut-facetimehd.conf /etc/dracut.conf.d/facetimehd.conf
# Allow user-writable screen backlight via udev
COPY 90-backlight.rules /etc/udev/rules.d/90-backlight.rules
# Allow user-writable keyboard backlight via udev
COPY 91-leds.rules /etc/udev/rules.d/91-leds.rules
# Disable XHC1/LID0 ACPI wakeup sources (prevents spurious wakeups)
COPY suspend-fix.service /usr/lib/systemd/system/suspend-fix.service

# ── System configuration & kernel module installation ──
RUN <<SYSCONFIG
set -euo pipefail

echo "▸ Creating required directories"
mkdir -vp /var/roothome /data /var/home

echo "▸ Installing kernel-modules-extra for broader hardware support"
dnf5 -y install kernel-modules-extra --refresh

# ── Dracut: strip unnecessary modules, add FaceTimeHD firmware ──
echo "▸ Configuring dracut: removing NFS, adding FaceTimeHD firmware"
tee /etc/dracut.conf.d/no-nfs.conf >/dev/null <<'NONFS'
omit_dracutmodules+=" nfs "
omit_drivers+=" nfs nfsv3 nfsv4 nfs_acl nfs_common sunrpc rxrpc rpcrdma auth_rpcgss rpcsec_gss_krb5 "
NONFS

echo "▸ Regenerating initramfs"
kver="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
dracut -f "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

# ── Kernel Arguments: ACPI OSI hacks for MacBook hardware ──
# Declaring kernel arguments via bootc-native configuration files.
mkdir -p /usr/lib/bootc/kargs.d/
echo 'kargs = ["acpi_osi=\"!Darwin\"", "acpi_osi=\"!Windows 2012\""]' > /usr/lib/bootc/kargs.d/10-macbook.toml

# ── Kernel Arguments: Intel GPU + PCIe power savings (MacBookAir7,2 / Broadwell) ──
# PSR: Panel Self Refresh — cuts eDP link power when framebuffer is static
# FBC: Frame Buffer Compression — compresses framebuffer in VRAM
# pcie_aspm=force: enables PCIe ASPM link power states
cat > /usr/lib/bootc/kargs.d/20-macbook-power.toml <<'KARGS'
kargs = ["i915.enable_psr=1", "i915.enable_fbc=1", "pcie_aspm=force"]
KARGS

# ── Audio power save (Intel HDA codec off when idle for 1s) ──
echo 'options snd_hda_intel power_save=1' > /etc/modprobe.d/audio-power-save.conf

# ── RPMFusion for broadcom-wl runtime dependencies ──
FEDORA_RELEASE="$(rpm -E '%fedora')"
dnf5 -y install \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# ── Install pre-built kernel modules ──
echo "▸ Installing Broadcom WiFi kernel module (kmod-wl)"
dnf5 -y install /tmp/kmods/kmod-wl-*.rpm

echo "▸ Installing FaceTimeHD camera kernel module (kmod-facetimehd)"
dnf5 -y install facetimehd-kmod-common
dnf5 -y install /tmp/kmods/kmod-facetimehd-*.rpm || \
    rpm -ivh --nodeps /tmp/kmods/kmod-facetimehd-*.rpm

# ── Writable directories (bootc best practice) ──
# See: https://bootc-dev.github.io/bootc/building/guidance.html
echo "▸ Setting up writable /opt and /usr/local"
rm -rvf /opt && mkdir -vp /var/opt && ln -vs /var/opt /opt
mkdir -vp /var/usrlocal && mv -v /usr/local/* /var/usrlocal/ 2>/dev/null || true
rm -rvf /usr/local && ln -vs /var/usrlocal /usr/local

# ── Timezone: Santiago, Chile ──
echo "▸ Setting timezone to America/Santiago"
ln -sf /usr/share/zoneinfo/America/Santiago /etc/localtime

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
grep -v '^\s*#' /tmp/packages.rpm | grep -v '^\s*$' | xargs dnf5 install -y --refresh
dnf5 remove -y gnome-tour

# ── Install macbook-lighter from source ──
echo "▸ Installing macbook-lighter from source"
git clone --depth 1 https://github.com/CleoMenezesJr/macbook-lighter.git /tmp/macbook-lighter
cd /tmp/macbook-lighter

echo "▸ Installing macbook-lighter scripts"
install -Dm755 src/macbook-lighter-ambient.sh /usr/bin/macbook-lighter-ambient
install -Dm755 src/macbook-lighter-screen.sh /usr/bin/macbook-lighter-screen
install -Dm755 src/macbook-lighter-kbd.sh /usr/bin/macbook-lighter-kbd

echo "▸ Installing macbook-lighter configuration"
install -Dm644 macbook-lighter.conf /etc/macbook-lighter.conf

echo "▸ Installing macbook-lighter systemd service"
install -Dm644 macbook-lighter.service /usr/lib/systemd/system/macbook-lighter.service

echo "▸ Installing macbook-lighter GNOME extension"
EXT_UUID="macbook-lighter@cleomenezesjr.github.io"
EXT_DEST="/usr/share/gnome-shell/extensions/${EXT_UUID}"
mkdir -p "${EXT_DEST}"
cp -r "gnome-extension/${EXT_UUID}/." "${EXT_DEST}/"

cd / && rm -rf /tmp/macbook-lighter

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

# ── GNOME system defaults via dconf ──
echo "▸ Configuring GNOME system defaults"
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/profile/user <<'DCONF_PROFILE'
user-db:user
system-db:local
DCONF_PROFILE
cat > /etc/dconf/db/local.d/00-gnome-extensions <<'DCONF_EXTENSIONS'
[org/gnome/shell]
enabled-extensions=['weather-oclock@cleomenezesjr.github.com', 'macbook-lighter@cleomenezesjr.github.io']
DCONF_EXTENSIONS
dconf update

# ── Configuring systemd services ──
echo "▸ Configuring systemd services"
# Mask unnecessary services
systemctl mask systemd-remount-fs.service

# Enable system-wide hardware services
systemctl enable \
    macbook-lighter.service \
    mbpfan.service \
    thermald.service \
    tuned.service \
    tuned-ppd.service \
    suspend-fix.service \
    zram-swap.service

# Enable user-level bootstrap services globally for all graphical sessions
systemctl --global enable \
    post-install.service

# ── Pre-seed system users/groups at build time ──
# Prevents systemd-sysusers from failing at boot on duplicate entries
# left behind by RPM scriptlets (e.g. usbmuxd group in /etc/gshadow).
# Must run AFTER all packages are installed so every sysusers.d entry is covered.
echo "▸ Pre-seeding system users via systemd-sysusers"
systemd-sysusers

# ── Final cleanup ──
echo "▸ Final cleanup for bootc compliance"
rm -f /tmp/packages.rpm
dnf5 clean all
rm -rfv /var/cache/* \
        /var/log/* \
        /var/tmp/* \
        /var/cache/libdnf5/* \
        /var/usrlocal/share/applications/mimeinfo.cache \
        /var/roothome/.*
# Final check for /usr/etc
rm -rvf /usr/etc
PACKAGES

# ── Lint the final image ──
RUN bootc container lint
