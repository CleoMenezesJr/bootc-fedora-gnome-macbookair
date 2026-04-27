#!/bin/bash
# Stop rpm-ostreed before suspend to avoid 35s+ resume delay.
# rpm-ostreed in idle state blocks systemd-suspend from thawing user.slice
# because it doesn't support freeze and has no ExecStop.
# It auto-exits after ~63s idle, but that's too long for resume.
case "$1" in
    pre)
        systemctl stop rpm-ostreed.service 2>/dev/null || true
        ;;
    post)
        # No need to start — it auto-starts on D-Bus activation when needed
        ;;
esac
