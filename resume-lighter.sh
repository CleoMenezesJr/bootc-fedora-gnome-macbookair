#!/bin/bash
# Restart macbook-lighter user service after S3 resume.
# This runs as a proper systemd service AFTER suspend.target,
# so user.slice is already thawed when ExecStop runs post-resume.
# The old restore-backlight.sh hook used to do this inside
# systemd-suspend's cgroup while user.slice was still frozen,
# causing a ~45s deadlock.
case "$1" in
 pre)
 # Nothing needed before suspend
 ;;
 post)
 for uid in $(loginctl list-sessions --no-legend | awk '{print $2}'); do
 if [ -S "/run/user/$uid/systemd/private" ]; then
 sudo -u "#$uid" XDG_RUNTIME_DIR="/run/user/$uid" \
 systemctl --user restart macbook-lighter.service 2>/dev/null || true
 fi
 done
 ;;
esac
