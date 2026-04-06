#!/bin/bash
# First-login bootstrap: installs Flatpak applications and GNOME extensions as --user.
# Runs once per user via a systemd user service (post-install.service).
set -euo pipefail

FLAG="${XDG_DATA_HOME:-$HOME/.local/share}/.flatpaks-bootstrapped"

# Skip if already completed
if [ -f "$FLAG" ]; then
    echo "Flatpaks already bootstrapped — skipping."
    exit 0
fi

echo "Adding Flathub remote (user-level)…"
flatpak remote-add --user --if-not-exists \
    flathub https://flathub.org/repo/flathub.flatpakrepo

echo "Installing Flatpak applications (user-level)…"
flatpak install --user --noninteractive flathub \
    com.github.tchx84.Flatseal \
    com.mattjakeman.ExtensionManager \
    dev.geopjr.Tuba \
    io.github.diegopvlk.Cine \
    io.neovim.nvim \
    net.nokyan.Resources \
    org.gnome.Calculator \
    org.gnome.Characters \
    org.gnome.Clocks \
    org.gnome.Evince \
    org.gnome.Fractal \
    org.gnome.Logs \
    org.gnome.Loupe \
    org.gnome.Maps \
    org.gnome.Snapshot \
    org.gnome.TextEditor \
    org.gnome.Weather \
    org.gnome.font-viewer \
    org.mozilla.firefox \
    org.telegram.desktop \
    page.tesk.Refine

# Mark as completed so this service won't run again
mkdir -p "$(dirname "$FLAG")"
touch "$FLAG"
echo "Flatpak bootstrap complete."
