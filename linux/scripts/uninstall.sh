#!/bin/sh
# Removes Araso, as root (About's Uninstall… runs it through pkexec; or `sudo /usr/lib/araso/uninstall.sh`).
# The users' settings folders (~/.config/araso) are theirs to keep or delete.
set -eu
for dir in /usr/lib/fcitx5 /usr/lib64/fcitx5 /usr/lib/*-linux-gnu/fcitx5; do
  rm -f "$dir/araso.so"
done
rm -f /usr/share/fcitx5/addon/araso.conf /usr/share/fcitx5/inputmethod/araso.conf \
      /usr/bin/araso-settings /usr/share/applications/araso-settings.desktop
for size in 16 22 24 32 48 64 128 256; do
  rm -f "/usr/share/icons/hicolor/${size}x${size}/apps/araso.png" \
        "/usr/share/icons/hicolor/${size}x${size}/apps/araso-paused.png"
done
rm -rf /usr/share/araso /usr/lib/araso
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q /usr/share/icons/hicolor || true; fi
echo "Araso is uninstalled. Restart fcitx5 (fcitx5 -r) so it lets go of it."
