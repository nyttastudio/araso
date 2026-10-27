#!/bin/sh
# Real typing in a Wayland session: sway without a screen, fcitx5 on it, a GTK field typed into with
# vkbd (a virtual keyboard with the US keymap). Once through fcitx5's GTK module (GTK_IM_MODULE=fcitx, over
# D-Bus) and once through Wayland's own text-input protocol, which sway hands to fcitx5.
set -u
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then exec dbus-run-session -- sh "$0" "$@"; fi
package=$1
here=$(cd "$(dirname "$0")" && pwd)
shots=${ARASO_SHOTS:-/tmp}
sh "$package/install.sh" >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }
mkdir -p "$HOME/.config/fcitx5" "$HOME/.config/araso"
printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=araso\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=araso\nLayout=\n\n[GroupOrder]\n0=Default\n' \
  > "$HOME/.config/fcitx5/profile"
export XDG_RUNTIME_DIR=/tmp/xdg LANG=C.UTF-8 LANGUAGE=ko
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman sway -c /dev/null >/tmp/sway.log 2>&1 &
for _ in $(seq 20); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 0.5; done
export WAYLAND_DISPLAY=wayland-1
unset DISPLAY
fcitx5 -d >/tmp/fcitx5.log 2>&1
sleep 3

failures=0
run() {  # name, GTK_IM_MODULE ("" for Wayland's text-input), keys, expected
  rm -f /tmp/out.txt "$HOME/.config/araso/dictionary.json"
  GTK_IM_MODULE=$2 python3 "$here/field.py" /tmp/out.txt >/dev/null 2>&1 &
  pid=$!
  sleep 2.5
  state=$(fcitx5-remote)
  if [ "$state" != 2 ]; then
    echo "FAIL $1 starts in Araso: fcitx5-remote says $state"; failures=$((failures + 1)); fcitx5-remote -o
  fi
  vkbd "$3"
  sleep 1
  grim "$shots/wayland-$(echo "$1" | tr ' ' '-').png" 2>/dev/null
  got=$(cat /tmp/out.txt 2>/dev/null; printf x)
  got=${got%x}
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1: expected \"$4\", got \"$got\""; failures=$((failures + 1)); fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
run "Wayland, GTK module" fcitx "dkssud hello " "안녕 hello "
run "Wayland, text-input" "" "dkssud hello " "안녕 hello "
run "Wayland, the switch key" "" "dkssud{AltR} " "dkssud "
run "Wayland, the 한/영 key" "" "dkssud{Hangul} " "dkssud "
echo "$failures failed"
exit "$failures"
