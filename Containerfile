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
    dnf5 -y install akmod-facetimehd
akmods --force --kernels "${KERNEL_VERSION}" --kmod facetimehd

# ── Build FaceTimeHD firmware ──
echo "▸ Building FaceTimeHD firmware from source"
git clone --depth 1 https://github.com/patjak/facetimehd-firmware.git /tmp/facetimehd-firmware
cd /tmp/facetimehd-firmware
make
make install
cd /
rm -rf /tmp/facetimehd-firmware

echo "▸ Builder stage complete"
BUILDER

# ── Stage 2: Final bootable image ──────────────────────────────────────────
FROM quay.io/fedora/fedora-bootc:44

# Copy pre-built kernel module RPMs from builder
COPY --from=builder /var/cache/akmods/wl/kmod-wl*.rpm /tmp/kmods/
COPY --from=builder /var/cache/akmods/facetimehd/kmod-facetimehd*.rpm /tmp/kmods/

# Copy FaceTimeHD firmware from builder
COPY --from=builder /usr/lib/firmware/facetimehd/ /usr/lib/firmware/facetimehd/

# Copy project configuration files
COPY packages.rpm post-install.sh post-install.service \
     hid-apple.conf dracut-facetimehd.conf \
     suspend-fix.service powertop.service ./

# ── System configuration & kernel module installation ──
RUN <<SYSCONFIG
set -euo pipefail

echo "▸ Creating required directories"
mkdir -vp /var/roothome /data /var/home

echo "▸ Upgrading all packages to latest versions"
dnf5 -y upgrade --refresh

echo "▸ Installing kernel-modules-extra for broader hardware support"
dnf5 -y install kernel-modules-extra --refresh

# ── Dracut: strip unnecessary modules, add FaceTimeHD firmware ──
echo "▸ Configuring dracut: removing NFS, adding FaceTimeHD firmware"
tee /etc/dracut.conf.d/no-nfs.conf >/dev/null <<'NONFS'
omit_dracutmodules+=" nfs "
omit_drivers+=" nfs nfsv3 nfsv4 nfs_acl nfs_common sunrpc rxrpc rpcrdma auth_rpcgss rpcsec_gss_krb5 "
NONFS

mv -v dracut-facetimehd.conf /etc/dracut.conf.d/facetimehd.conf

echo "▸ Regenerating initramfs"
kver="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
dracut -f "/usr/lib/modules/${kver}/initramfs.img" "${kver}"

# ── RPMFusion for broadcom-wl runtime dependencies ──
FEDORA_RELEASE="$(rpm -E '%fedora')"
dnf5 -y install \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_RELEASE}.noarch.rpm"

# ── Install pre-built kernel modules ──
echo "▸ Installing Broadcom WiFi kernel module (kmod-wl)"
dnf5 -y install /tmp/kmods/kmod-wl-*.rpm

echo "▸ Installing FaceTimeHD camera kernel module (kmod-facetimehd)"
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

# ── MacBook keyboard configuration ──
echo "▸ Installing MacBook keyboard configuration (hid_apple)"
mv -v hid-apple.conf /etc/modprobe.d/hid-apple.conf

# ── Systemd services: user-level Flatpak bootstrap ──
echo "▸ Installing post-install script and user service"
mv -v post-install.sh /usr/bin/post-install.sh
chmod +x /usr/bin/post-install.sh
# User service goes to /usr/lib/systemd/user/ (not /etc/)
mkdir -p /usr/lib/systemd/user/
mv -v post-install.service /usr/lib/systemd/user/post-install.service
# Enable globally for all users
systemctl --global enable post-install.service

# ── MacBook-specific systemd services ──
echo "▸ Installing MacBook hardware services"
mv -v suspend-fix.service /usr/lib/systemd/system/suspend-fix.service
mv -v powertop.service /usr/lib/systemd/system/powertop.service
systemctl enable suspend-fix.service
systemctl enable powertop.service

# ── Cleanup builder artifacts ──
echo "▸ Cleaning up build artifacts"
rm -rvf /tmp/kmods
dnf5 clean all
# Avoid touching /var directly (bootc limitation)
SYSCONFIG

# ── Install GNOME Shell (minimal, no weak deps) ──
RUN echo "▸ Installing GNOME Shell (minimal)" && \
    dnf5 install gnome-shell --setopt=install_weak_deps=False -y && \
    dnf5 clean all

# ── Install RPM packages from list & configure services ──
RUN <<PACKAGES
set -euo pipefail

echo "▸ Installing RPM packages from packages.rpm"
grep -v '^\s*#' packages.rpm | grep -v '^\s*$' | xargs dnf5 install -y

# ── Install macbook-lighter (ambient light sensor control) ──
echo "▸ Installing macbook-lighter from source"
dnf5 -y install git
git clone --depth 1 https://github.com/harttle/macbook-lighter.git /tmp/macbook-lighter
cd /tmp/macbook-lighter
install -Dm644 macbook-lighter.conf /etc/macbook-lighter.conf
install -Dm644 macbook-lighter.service /usr/lib/systemd/system/macbook-lighter.service
install -Dm755 src/macbook-lighter-ambient.sh /usr/bin/macbook-lighter-ambient
install -Dm755 src/macbook-lighter-screen.sh /usr/bin/macbook-lighter-screen
install -Dm755 src/macbook-lighter-kbd.sh /usr/bin/macbook-lighter-kbd
cd /
rm -rf /tmp/macbook-lighter

echo "▸ Configuring systemd services"
systemctl mask systemd-remount-fs.service
systemctl enable zram-swap.service
systemctl enable macbook-lighter.service

echo "▸ Final cleanup"
rm -rvf packages.rpm
dnf5 clean all
rm -rfv /var/usrlocal/share/applications/mimeinfo.cache
PACKAGES

# ── Lint the final image ──
RUN bootc container lint
