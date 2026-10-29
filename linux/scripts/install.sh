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
  echo "  Fedora: sudo dnf install fcitx5 fcitx5-gtk fcitx5-qt qt5-qtbase-gui   Arch: sudo pacman -S fcitx5 fcitx5-gtk fcitx5-qt qt5-base" >&2
  exit 1
fi

# The settings window (also what checks for updates) is a Qt program, and the package doesn't
# carry Qt: the command that installs the Qt libraries it's missing here, by distribution.
qtHint() {
  major=$1 like=""
  [ -r /etc/os-release ] && like=$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")
  case " $like " in
    *" arch "*) echo "sudo pacman -S qt$major-base" ;;
    *" fedora "*|*" rhel "*) echo "sudo dnf install qt$major-qtbase-gui" ;;
    *" suse "*|*" opensuse "*) echo "sudo zypper install libQt${major}Widgets$major libQt${major}Network$major" ;;
    *" debian "*|*" ubuntu "*) echo "sudo apt install libqt${major}widgets$major libqt${major}network$major" ;;
    *) echo "the Qt $major Widgets and Network libraries (Debian/Ubuntu: libqt${major}widgets$major libqt${major}network$major, Fedora: qt$major-qtbase-gui, Arch: qt$major-base)" ;;
  esac
}

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

# fcitx5 loads addons as it starts: restart a running one. It restarts itself (D-Bus), so it keeps
# the desktop's environment; one started here would have this shell's, and over SSH that has no
# display, so the settings window it opens from the tray couldn't start.
# It won't when it can't come back by itself (CanRestart false: holding a Wayland compositor's
# socket, as under KDE or sway), and then says nothing; the user restarts it on the desktop.
# fcitx5 before 5.1 (Ubuntu 22.04's 5.0.14) has Restart but no CanRestart.
controller() {  # method: its reply
  if command -v dbus-send >/dev/null 2>&1; then
    dbus-send --session --print-reply --dest=org.fcitx.Fcitx5 /controller "org.fcitx.Fcitx.Controller1.$1" 2>/dev/null
  else
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller --method "org.fcitx.Fcitx.Controller1.$1" 2>/dev/null
  fi
}
if pgrep -u "$(id -u)" -x fcitx5 >/dev/null 2>&1; then
  desktop="Restart fcitx5 to load Araso: log out and back in, or run fcitx5 -r in a terminal on the desktop."
  if ! command -v dbus-send >/dev/null 2>&1 && ! command -v gdbus >/dev/null 2>&1; then
    fcitx5 -r -d >/dev/null 2>&1 || true
    echo "Restarted fcitx5."
  elif can=$(controller CanRestart) && ! echo "$can" | grep -q true; then
    # fcitx5 -r doesn't replace it either then: only a new session does.
    echo "fcitx5 can't restart itself here: log out and back in to load Araso."
  elif controller Restart >/dev/null; then
    echo "Restarted fcitx5."
  else
    echo "$desktop"
  fi
fi
cat <<'MSG'
Araso is installed. Add it once in fcitx5's settings: Input Method → Available Input Method →
Araso (or run fcitx5-configtool). It then starts on in every text field (it turns on fcitx5's
Active By Default; araso-settings → Languages turns that off). Settings: araso-settings, or
Araso's menu in the tray.
MSG
missing=$(ldd /usr/bin/araso-settings 2>/dev/null | awk '/libQt.*not found/ { print $1 }')
if [ -n "$missing" ]; then
  major=5
  case $missing in *libQt6*) major=6 ;; esac
  echo
  echo "The settings window can't start yet: Qt $major isn't installed ($(echo $missing | tr ' ' ',')). Typing works"
  echo "without it. Install it with:"
  echo "  $(qtHint $major)"
fi
