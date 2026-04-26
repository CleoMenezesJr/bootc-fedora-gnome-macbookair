# MacBook Air A1466 — Comprehensive Bootc Image Optimization

**Date**: 2026-04-26
**Scope**: Full optimization of the bootc-fedora-gnome-macbookair image across kernel, power management, suspend reliability, GNOME desktop, audio, Wi-Fi, fan control, dracut, and Containerfile structure
**Hardware**: MacBook Air A1466 (Mid 2012-2017), Intel Broadwell i5-5250U, i915 GPU, BCM4360 WiFi, bcm5974 trackpad, applesmc SMC
**Base**: Fedora 44 + GNOME Shell, bootc/ostree, btrfs

---

## Phase 1: Kernel Arguments + Modules (low risk)

### 1.1 Refine GPU + PCIe kernel args

**File**: Containerfile — `20-macbook-power.toml` heredoc

**Current**:
```toml
kargs = ["i915.enable_psr=0", "i915.enable_dc=0", "i915.enable_fbc=1", "pcie_aspm=force", "mem_sleep_default=deep"]
```

**Proposed**:
```toml
kargs = [
  "i915.enable_psr=1",      # Re-enable PSR — cuts eDP link power when framebuffer is static
  "i915.enable_dc=2",       # DC5/DC6 deepest display power states
  "i915.enable_fbc=1",      # Frame Buffer Compression (stable, kept)
  "i915.enable_guc=2",      # Load GuC/HuC firmware for GPU power management + VA-API
  "pcie_aspm=active",       # Safer than force — only enables ASPM on devices that support it
  "mem_sleep_default=deep"  # S3 suspend-to-RAM (correct for Broadwell)
]
match-architectures = ["x86_64"]
```

**Rationale**:
- `enable_psr=0` and `enable_dc=0` were workarounds for black screen on S3 resume. With the `restore-backlight.sh` hook and lid-wakeup-guard (Phase 3), we can test re-enabling them. PSR saves significant power by stopping display refresh when static.
- `enable_guc=2`: GuC manages GPU workload submission, HuC loads firmware for video decode. Improves GPU power management and is required for VA-API with `intel-media-driver` on Broadwell.
- `pcie_aspm=active` instead of `force`: `force` enables ASPM on devices that declare they don't support it, which can cause latency on some controllers. `active` only enables on supported devices — still saves power but safer.
- If PSR/DC cause black screen again, revert to `=0`.

### 1.2 New kernel args for NVMe + USB

**File**: Containerfile — new `30-macbook-hardware.toml` heredoc

```toml
kargs = [
  "nvme_core.default_ps_max_latency_us=55000",  # Allow NVMe PS3 (~55ms resume) but not PS4 (causes hangs)
  "usbcore.autosuspend=5"                         # USB autosuspend after 5s
]
match-architectures = ["x86_64"]
```

**Rationale**:
- `nvme_core.default_ps_max_latency_us=55000`: Some MacBook SSDs hang on resume from deep NVMe power states. 55000us allows PS3 (moderate savings) but blocks PS4 (deep sleep that causes hangs).
- `usbcore.autosuspend=5`: Default is 2s which is aggressive. 5s balances power savings with device responsiveness. The bcm5974 trackpad is excluded separately via udev rule.

### 1.3 Kernel modules to load at boot

**New file**: `modules-load.conf`
```
# /usr/lib/modules-load.d/macbook.conf
# Ensure these modules are loaded at boot for hardware support
coretemp
applesmc
```

**Rationale**: `applesmc` is essential for mbpfan and macbook-lighter. `coretemp` provides CPU temperature readings. Neither is guaranteed to auto-load on all kernel versions.

### 1.4 Audio power save

**New file**: `audio-power-save.conf`
```ini
# /usr/lib/modprobe.d/audio-power-save.conf
options snd_hda_intel power_save=1
```

**Rationale**: Already exists in the Containerfile as a RUN echo command. Extracting to a proper file is cleaner and consistent with the other modprobe configs.

### 1.5 Wi-Fi power save

**New file**: `wifi-power-save.conf`
```ini
# /usr/lib/modprobe.d/wifi-power-save.conf
# Broadcom wl driver IEEE 802.11 power management
options wl power_save=1
```

**Rationale**: The BCM4360 with the proprietary `wl` driver supports basic 802.11 power save. `power_save=1` enables it. Limited effect but zero risk.

---

## Phase 2: Power Management Consolidation (medium risk)

### 2.1 Replace powertop --auto-tune with tuned custom profile

**Problem**: `powertop --auto-tune` is a blunt hammer — it changes ALL tunables at once including USB autosuspend settings that can cause the bcm5974 trackpad to disconnect after S3 resume. It also competes with `suspend-fix.service` (order not guaranteed).

**Solution**: Custom tuned profile that applies exactly the tunables we want.

**New directory**: `tuned-macbook-profile/`

**`tuned-macbook-profile/tuned.conf`**:
```ini
[main]
summary=MacBook Air A1466 power optimization

[cpu]
governor=powersave
energy_perf_bias=balance_power

[audio]
power_save=1
power_save_controller=yes

[disk]
# SATA/NVMe link power management
apm=254
spindown=0

[sysctl]
# Reduce VM swappiness — zram handles swap, no need to be aggressive
vm.swappiness=30
# Reduce dirty writeback to minimize I/O wakeups
vm.dirty_writeback_centisecs=1500
vm.dirty_expire_centisecs=3000

[usb]
# Autosuspend after 2s — bcm5974 trackpad excluded via udev rule
autosuspend=2
```

**`tuned-macbook-profile/profile.toml`** (metadata — tuned requires this):
```ini
[profile]
name=macbook-profile
summary=MacBook Air A1466 power optimization
```

**Containerfile changes**:
- Remove `powertop.service` COPY and enable
- Add `COPY tuned-macbook-profile/ /etc/tuned/macbook-profile/`
- Change tuned enable to: `systemctl enable tuned.service tuned-ppd.service`
- Set the profile: add `RUN tuned-adm profile macbook-profile` in the PACKAGES block
- Keep `powertop` in packages.rpm as a diagnostic tool (not auto-run)

### 2.2 Trackpad USB autosuspend exclusion

**New file**: `92-trackpad-autosuspend.rules`
```
# Prevent bcm5974 trackpad from entering USB autosuspend
# The autosuspend can cause trackpad disconnect after S3 resume
# and add latency on first touch after idle period
# Cost: ~10-20mW when idle (negligible)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="026*", ATTR{power/autosuspend}="-1"
```

**Rationale**: The bcm5974 communicates via USB. When USB autosuspend powers down the port, the trackpad can lose its multitouch mode and fail to recover after S3 resume. Excluding it costs negligible power (~10-20mW) but eliminates a common reliability issue.

### 2.3 mbpfan custom fan curve

**New file**: `mbpfan.conf`
```ini
[general]
min_speed=1300
max_speed=6200
low_temp=55
high_temp=70
max_temp=90
polling_interval=5
```

**Rationale**:
| Value | Why |
|-------|-----|
| `min_speed=1300` | Real hardware minimum (`fan1_min` from applesmc). macOS uses this value. The default 2000 was artificially high. |
| `max_speed=6200` | Real hardware maximum for A1466. |
| `low_temp=55` | Below this → fan at minimum. A1466 idles at ~45-50°C. 55°C is comfortable on lap. Default 63°C was too high — laptop got warm before fan ramped up. |
| `high_temp=70` | Above this → fan scales linearly. 15°C gap gives a smooth curve. Default gap (63→66, 3°C) caused abrupt fan jumps. |
| `max_temp=90` | Above this → fan at maximum. 10°C margin before Tjunction Max (100°C for Broadwell U-series). Default 86°C was too conservative. |
| `polling_interval=5` | 5s is sufficient for thermal response. Default 1s = 80% more CPU wakeups for no perceptible benefit. |

### 2.4 Integrate wl-suspend as systemd service

**Problem**: `wl-suspend.sh` exists in the repo but is neither copied in the Containerfile nor enabled as a service. The Broadcom `wl` module can be slow to resume from S3 (firmware re-init). Unloading before sleep and reloading after wake is faster.

**Existing file**: `wl-suspend.sh` (no changes needed)
```bash
#!/bin/bash
case "$1" in
pre) modprobe -r wl ;;
post) modprobe wl ;;
esac
```

**New file**: `wl-suspend.service`
```ini
[Unit]
Description=Unload/Reload Broadcom wl module on suspend/resume
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/wl-suspend.sh pre
ExecStop=/usr/local/bin/wl-suspend.sh post

[Install]
WantedBy=sleep.target
```

**Containerfile changes**:
- Add `COPY --chmod=755 wl-suspend.sh /usr/local/bin/wl-suspend.sh`
- Add `COPY wl-suspend.service /usr/lib/systemd/system/wl-suspend.service`
- Add `wl-suspend.service` to systemctl enable block

### 2.5 Suspend-then-hibernate

**Problem**: S3 (suspend-to-RAM) consumes some power overnight. Hibernation (S4) has zero drain but slow resume. Best of both worlds: suspend first (fast resume), hibernate after timeout (zero drain).

**New file**: `sleep.conf`
```ini
# /usr/lib/systemd/sleep.conf.d/macbook.conf
[Sleep]
HibernateDelaySec=60min
SuspendMode=s2idle deep
HibernateMode=platform shutdown
```

**New file**: `logind.conf`
```ini
# /usr/lib/systemd/logind.conf.d/macbook.conf
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend
IdleAction=suspend-then-hibernate
IdleActionSec=900
```

**Behavior**:
- Close lid → S3 (instant resume)
- After 60min without opening → hibernate (zero drain)
- Open before 60min → normal S3 resume
- On AC power with lid closed → regular suspend (no hibernate, no point)

### 2.6 Remove powertop.service

**Action**: Remove the `powertop.service` file and its COPY/enable from the Containerfile. The tuned custom profile replaces it with more targeted, controlled power savings. Keep `powertop` package installed as diagnostic tool.

---

## Phase 3: Lid Wakeup + Suspend Reliability

### 3.1 Re-enable LID0 as wakeup source

**Problem**: The current `suspend-fix.service` disables LID0 as a wakeup source, which prevents the MacBook from waking when the lid is opened. This was a workaround for spurious lid sensor flickers that wake the system while the lid is closed.

**Solution**: Re-enable LID0 but add a guard that re-suspends if the lid is actually still closed after wakeup. Plus a rate limiter that disables LID0 if it flickers too often.

**Modified file**: `suspend-fix.service` — remove LID0 from the list:
```ini
ExecStart=/bin/sh -c 'for src in XHC1 EHC1 EHC2; do grep -Eqw "$src.*\*enabled" /proc/acpi/wakeup 2>/dev/null && echo "$src" > /proc/acpi/wakeup || true; done'
```

### 3.2 Lid wakeup guard with rate limiting

**New file**: `lid-wakeup-guard.sh`
```bash
#!/bin/bash
# After resume, verify the lid is actually open.
# If closed, re-suspend. Rate limit: if 3+ wakeups in 60s
# with lid closed, disable LID0 wakeup and log for diagnostics.
RATE_FILE="/run/lid-wakeup-count"
TIME_FILE="/run/lid-wakeup-last"

sleep 5

LID_STATE=$(cat /proc/acpi/button/lid/LID0/state 2>/dev/null | awk '{print $2}')

if [ "$LID_STATE" = "closed" ]; then
  NOW=$(date +%s)
  PREV=$(cat "$TIME_FILE" 2>/dev/null || echo 0)
  COUNT=$(cat "$RATE_FILE" 2>/dev/null || echo 0)

  # Reset counter if more than 60s since last event
  if [ $((NOW - PREV)) -gt 60 ]; then
    COUNT=1
  else
    COUNT=$((COUNT + 1))
  fi

  echo "$COUNT" > "$RATE_FILE"
  echo "$NOW" > "$TIME_FILE"

  # If 3+ wakeups in 60s with lid closed → disable LID0
  if [ "$COUNT" -ge 3 ]; then
    logger -t lid-wakeup-guard "Disabling LID0 wakeup after $COUNT spurious wakeups"
    echo "LID0" > /proc/acpi/wakeup
  fi

  systemctl suspend
else
  # Lid is open — reset counter and re-enable LID0 if needed
  echo "0" > "$RATE_FILE"
  grep -Eqw "LID0.*\*disabled" /proc/acpi/wakeup 2>/dev/null && \
    echo "LID0" > /proc/acpi/wakeup
fi
```

**New file**: `lid-wakeup-guard.service`
```ini
[Unit]
Description=Verify lid is open after wakeup, re-suspend if not
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lid-wakeup-guard.sh

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

### 3.3 Udev rule to re-enable LID0 on lid open

**New file**: `93-lid-wakeup.rules`
```
# Re-enable LID0 as wakeup source when lid opens
# (may have been disabled by lid-wakeup-guard due to spurious wakeups)
ACTION=="change", SUBSYSTEM=="acpi", KERNEL=="LID0", ATTR{state}=="open", \
  RUN+="/bin/sh -c 'grep -Eqw \"LID0.*\\*disabled\" /proc/acpi/wakeup && echo LID0 > /proc/acpi/wakeup || true'"
```

### 3.4 Behavior summary

| Situation | Behavior | Power cost |
|-----------|----------|------------|
| Lid opens | LID0 wakeup → system wakes → guard sees "open" → normal | Zero extra |
| Spurious flicker (1-2x) | Wakes → guard sees "closed" → re-suspends in 5s | ~0.04Wh per event |
| Spurious cascade (3x in 60s) | Guard disables LID0 → stops waking | Zero after disabled |
| Next real lid open | udev re-enables LID0 → works normally | Zero extra |

---

## Phase 4: GNOME + Desktop Optimizations

All settings are system defaults via `/etc/dconf/db/local.d/`. Users can override individually.

### 4.1 Mutter experimental features

**New file**: Containerfile dconf block `03-mutter`
```ini
[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer', 'kms-modifiers', 'autoclose-xwayland']
```

- `kms-modifiers`: Buffer allocation with explicit DRM modifiers — better i915 performance
- `autoclose-xwayland`: Terminates Xwayland when no X11 apps remain — frees RAM
- `scale-monitor-framebuffer`: Per-monitor fractional scaling support

### 4.2 Font rendering (non-Retina 1366x768)

**New file**: Containerfile dconf block `04-fonts`
```ini
[org/gnome/desktop/interface]
font-antialiasing='rgba'
font-hinting='slight'
font-rgba-order='rgb'
```

**Rationale**: The A1466 has a 1366x768 non-Retina display. Subpixel rendering (RGBA) significantly improves text clarity at low DPI. On HiDPI displays this would be unnecessary, but at 1366x768 it's important.

### 4.3 Power saving

**New file**: Containerfile dconf block `05-power`
```ini
[org/gnome/settings-daemon/plugins/power]
idle-dim=true
idle-brightness=20
sleep-inactive-battery-timeout=600
sleep-inactive-battery-type='suspend-then-hibernate'
power-saver-profile-on-low-battery=true

[org/gnome/desktop/session]
idle-delay=120
```

### 4.4 Night Light

**New file**: Containerfile dconf block `06-nightlight`
```ini
[org/gnome/settings-daemon/plugins/color]
night-light-enabled=true
night-light-temperature=3500
night-light-schedule-automatic=true
```

**Rationale**: 3500K is a comfortable evening warmth — less aggressive than the default 2700K (candlelight-adjacent). Automatic schedule uses geolocation for sunrise/sunset.

### 4.5 Responsiveness

**New file**: Containerfile dconf block `07-responsiveness`
```ini
[org/gnome/mutter]
check-alive-timeout=uint32 3000

[org/gnome/desktop/interface]
enable-animations=true
overlay-scrolling=true
```

**Rationale**: `check-alive-timeout=3000` detects unresponsive apps in 3s instead of the default 5s. Animations kept — GNOME 48's dynamic triple buffering helps significantly on Haswell/Broadwell.

### 4.6 Mask Tracker indexer

**Containerfile change**: Add to systemctl mask block:
```
tracker-miner-fs-3.service
tracker-extract-3.service
```

**Rationale**: Tracker indexes files for search. On a lightweight desktop with SSD, the I/O and CPU overhead is not worth the benefit. Users can still search files via Nautilus without Tracker.

---

## Phase 5: Containerfile Reorganization + Bootc Best Practices

### 5.1 Layer structure

Reorganize the Containerfile into logical layers for better cache utilization and maintainability:

```dockerfile
# Stage 1: Builder (kernel modules) — unchanged

# Stage 2: Final image
FROM quay.io/fedora/fedora-bootc:44

# 2.1 — COPY all configuration files (before any RUN)
# 2.2 — SYSCONFIG: kernel args, modprobe, dracut, modules-load,
#        composefs, systemd services/sleep/logind, tmpfiles.d
# 2.3 — GNOME: install gnome-shell (separate layer for cache)
# 2.4 — PACKAGES: install packages + macbook-lighter + mbpfan
# 2.5 — DCONF: all GNOME configuration in isolated block
# 2.6 — SERVICES: systemctl enable/mask
# 2.7 — CLEANUP + LINT
```

### 5.2 Enable composefs

Add to SYSCONFIG block:
```bash
mkdir -p /usr/lib/ostree
cat > /usr/lib/ostree/prepare-root.conf <<'EOF'
[composefs]
enabled = true
EOF
```

**Rationale**: Composefs makes the entire `/` a read-only filesystem with integrity verification via fsverity. This is recommended by bootc and prepares the path for future systemd-boot migration. Works with GRUB normally.

### 5.3 Integrate all new files

Add COPY directives for all new files created in Phases 1-4:
- `modules-load.conf` → `/usr/lib/modules-load.d/macbook.conf`
- `92-trackpad-autosuspend.rules` → `/usr/lib/udev/rules.d/`
- `lid-wakeup-guard.sh` → `/usr/local/bin/`
- `lid-wakeup-guard.service` → `/usr/lib/systemd/system/`
- `93-lid-wakeup.rules` → `/usr/lib/udev/rules.d/`
- `wifi-power-save.conf` → `/usr/lib/modprobe.d/`
- `dracut-optimize.conf` → `/usr/lib/dracut/conf.d/` (replaces `no-nfs.conf`)
- `mbpfan.conf` → `/etc/mbpfan.conf`
- `wl-suspend.sh` → `/usr/local/bin/`
- `wl-suspend.service` → `/usr/lib/systemd/system/`
- `sleep.conf` → `/usr/lib/systemd/sleep.conf.d/macbook.conf`
- `logind.conf` → `/usr/lib/systemd/logind.conf.d/macbook.conf`
- `tuned-macbook-profile/` → `/etc/tuned/macbook-profile/`

### 5.4 Replace tmpfiles.d dynamic generation

**Current**: Uses `find /var -mindepth 1 -maxdepth 4 -type d` to generate tmpfiles.d entries dynamically. This is fragile — depends on build state and may miss or include wrong entries.

**Proposed**: Declare directories explicitly in the Containerfile. Only directories that the image creates (not package-installed ones — those are handled by their own tmpfiles.d).

### 5.5 Remove obsolete files

- Remove `dracut-facetimehd.conf` — consolidated into `dracut-optimize.conf` (add_dracutmodules + install_items)
- Remove `no-nfs.conf` (never was a separate file, but the heredoc in Containerfile) — consolidated into `dracut-optimize.conf`
- Remove `powertop.service` — replaced by tuned profile

### 5.6 Consolidate audio-power-save

Move from RUN echo in Containerfile to proper `audio-power-save.conf` file with COPY.

### 5.7 Service enable/mask block

**Enable**:
```
mbpfan.service
tuned.service
tuned-ppd.service
suspend-fix.service
zram-swap.service
wl-suspend.service
lid-wakeup-guard.service
```

**Mask** (additions marked with +):
```
systemd-remount-fs.service
rpc-gssd.service
chronyd.service
bootc-fetch-apply-updates.timer
tracker-miner-fs-3.service        # +
tracker-extract-3.service          # +
```

**Remove from enable**:
```
powertop.service  # replaced by tuned profile
```

---

## Backlog (future)

| Item | Status | Dependency |
|------|--------|------------|
| systemd-boot migration | Blocked | bootc issue #92 + #2098, ostree PR #3359 |
| Composefs + systemd-boot for fresh installs | Works today | `bootc install --bootloader systemd --composefs-backend` |
| systemd-boot via ISO | Blocked | bootc-image-builder needs `--bootloader systemd` support |

See team memory `systemd-boot-backlog.md` for full research details.

---

## New Files Summary

| File | Phase | Purpose |
|------|-------|---------|
| `modules-load.conf` | 1 | Ensure coretemp + applesmc loaded at boot |
| `audio-power-save.conf` | 1 | snd_hda_intel power_save=1 (extracted from Containerfile) |
| `wifi-power-save.conf` | 1 | Broadcom wl power_save=1 |
| `tuned-macbook-profile/tuned.conf` | 2 | Custom tuned profile replacing powertop |
| `tuned-macbook-profile/profile.toml` | 2 | tuned profile metadata |
| `92-trackpad-autosuspend.rules` | 2 | Exclude bcm5974 from USB autosuspend |
| `mbpfan.conf` | 2 | Custom fan curve for A1466 |
| `wl-suspend.service` | 2 | Systemd service for wl module suspend hook |
| `sleep.conf` | 2 | suspend-then-hibernate with 60min delay |
| `logind.conf` | 2 | Lid switch → suspend-then-hibernate |
| `lid-wakeup-guard.sh` | 3 | Verify lid open after resume + rate limit |
| `lid-wakeup-guard.service` | 3 | Run guard after each resume |
| `93-lid-wakeup.rules` | 3 | Re-enable LID0 when lid opens |
| `dracut-optimize.conf` | 1 | Expanded dracut optimization (replaces no-nfs.conf) |

## Modified Files Summary

| File | Phase | Change |
|------|-------|--------|
| `Containerfile` | 1-5 | Refine kernel args, add kargs.d, reorganize layers, add COPYs, enable/mask services, composefs, dconf blocks, remove powertop.service |
| `packages.rpm` | — | No changes (powertop stays as diagnostic tool) |
| `suspend-fix.service` | 3 | Remove LID0 from wakeup disable list |
| `wl-suspend.sh` | 2 | No content change, just now properly integrated |

## Removed Files

| File | Phase | Reason |
|------|-------|--------|
| `powertop.service` | 2 | Replaced by tuned custom profile |
| `dracut-facetimehd.conf` | 5 | Consolidated into dracut-optimize.conf |
