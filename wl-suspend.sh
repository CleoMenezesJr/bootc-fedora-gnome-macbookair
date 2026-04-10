#!/bin/bash
# Unload Broadcom wl module before S3 sleep and reload on resume.
# Resuming wl in-place is slow (firmware re-init); unload/reload is faster.

case "$1" in
    pre)  modprobe -r wl ;;
    post) modprobe wl ;;
esac
