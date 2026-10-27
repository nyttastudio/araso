#!/bin/sh
# Installs Araso for fcitx5 from the package this script sits in (build.sh stages it; a release's
# Araso-linux-<arch>.tar.gz holds it), or, from a source checkout, builds it first. Asks for
# root through sudo. Then restarts fcitx5; Araso is added as an input method by the user, in
# fcitx5's settings (Input Method → Araso), as on macOS no installer turns it on.
#   install.sh [--uninstall]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
if [ ! -d "$here/files" ]; then
  # In the source tree (linux/scripts): build the package, then install it.
  root=$(cd "$here/../.." && pwd)
  sh "$here/build.sh"
  exec sh "$root/build/linux/package/Araso-linux-$(uname -m)/install.sh" "$@"
fi
sudo=""
[ "$(id -u)" = 0 ] || sudo=sudo

if [ "${1:-}" = "--uninstall" ]; then
  $sudo sh "$here/uninstall.sh"
  exit 0
fi

# fcitx5's addon folder: where its own addons are (Debian/Ubuntu: lib/<triplet>/fcitx5, Fedora:
# lib64/fcitx5, Arch: lib/fcitx5).
addons=""
for dir in /usr/lib/*-linux-gnu/fcitx5 /usr/lib64/fcitx5 /usr/lib/fcitx5; do
  if [ -e "$dir/libclassicui.so" ] || [ -e "$dir/libdbus.so" ] || [ -e "$dir/libdbusfrontend.so" ]; then
    addons=$dir
    break
  fi
done
if [ -z "$addons" ]; then
  echo "fcitx5 isn't installed (its addon folder wasn't found). Install fcitx5 first:" >&2
  echo "  Debian/Ubuntu: sudo apt install fcitx5 fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5" >&2
  echo "    (and fcitx5-frontend-qt6 where there is one: Ubuntu 24.04 and later)" >&2
  echo "  Fedora: sudo dnf install fcitx5 fcitx5-gtk fcitx5-qt   Arch: sudo pacman -S fcitx5 fcitx5-gtk fcitx5-qt" >&2
  exit 1
fi

echo "Installing Araso $(cat "$here/VERSION" 2>/dev/null || echo) (fcitx5 addons: $addons)"
$sudo sh -c "
  set -e
  rm -rf /usr/lib/araso /usr/share/araso
  # Unlinked, not written over: a running araso-settings or fcitx5 keeps the old file (writing
  # into a running program fails, Text file busy; into a loaded library, corrupts it).
  (cd '$here/files/usr' && find . -type f) | while read -r file; do rm -f \"/usr/\$file\"; done
  cp -R '$here/files/usr/.' /usr/
  install -m 755 '$here/files/addon/araso.so' '$addons/araso.so'
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q /usr/share/icons/hicolor || true; fi
"

# fcitx5 loads addons as it starts: restart a running one (as this user, in this session).
if pgrep -u "$(id -u)" -x fcitx5 >/dev/null 2>&1; then
  fcitx5 -r -d >/dev/null 2>&1 || true
  echo "Restarted fcitx5."
fi
cat <<'MSG'
Araso is installed. Add it once in fcitx5's settings: Input Method → Available Input Method →
Araso (or run fcitx5-configtool). It then starts on in every text field (it turns on fcitx5's
Active By Default; araso-settings → Languages turns that off). Settings: araso-settings, or
Araso's menu in the tray.
MSG
