#!/bin/sh
# Inside a machine with fcitx5 and no Swift (run.sh starts one in Docker): installs the package,
# starts X (Xvfb), D-Bus and fcitx5 with Araso in its group, and types into a GTK field with
# xdotool, real key events through fcitx5's GTK module. Prints ok/FAIL per case.
set -u
# One D-Bus session for fcitx5 and the apps: the script runs again inside it.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then exec dbus-run-session -- sh "$0" "$@"; fi
package=$1
here=$(cd "$(dirname "$0")" && pwd)
shots=${ARASO_SHOTS:-/tmp}
sh "$package/install.sh" >/tmp/install.log 2>&1 || { cat /tmp/install.log; exit 1; }

mkdir -p "$HOME/.config/fcitx5" "$HOME/.config/araso"
cat > "$HOME/.config/fcitx5/profile" <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=araso

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=araso
Layout=

[GroupOrder]
0=Default
PROFILE
export DISPLAY=:1 GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx LANG=C.UTF-8 LANGUAGE=ko
Xvfb :1 -screen 0 1000x700x24 >/dev/null 2>&1 &
sleep 1

failures=0
reload() {  # what the settings window does after writing a file
  python3 -c 'import os,socket; s=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM); r=os.environ.get("XDG_RUNTIME_DIR"); d=r + "/araso" if r else "/tmp/araso-%d" % os.getuid(); s.sendto(b"{\"op\":\"reload\"}", d + "/ime")'
  sleep 0.5
}
on() {  # a new field starts in Araso (fcitx5's Active By Default, turned on by the addon)
  state=$(fcitx5-remote)
  if [ "$state" != 2 ]; then
    echo "FAIL $1 starts in Araso: fcitx5-remote says $state"; failures=$((failures + 1)); fcitx5-remote -o
  fi
}
field() {  # starts a fresh field, in Araso, with nothing learned yet
  rm -f /tmp/out.txt "$HOME/.config/araso/dictionary.json"
  reload
  python3 "$here/field.py" /tmp/out.txt >/dev/null 2>&1 &
  field_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    xdotool search --name "Araso typing test" >/dev/null 2>&1 && break
    sleep 0.5
  done
  xdotool search --name "Araso typing test" windowfocus --sync >/dev/null 2>&1
  sleep 0.6
  on "a new field"
}
expect() {  # name, expected text
  sleep 0.8
  got=$(cat /tmp/out.txt 2>/dev/null; printf x)  # the x keeps a trailing newline
  got=${got%x}
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected \"$2\", got \"$got\""; failures=$((failures + 1)); fi
  kill "$field_pid" 2>/dev/null
  wait "$field_pid" 2>/dev/null
}

fcitx5 -d --verbose='araso=5' >/tmp/fcitx5.log 2>&1
# ARASO_SLOW (seconds): more time for the models and the kanji dictionary to load, under emulation.
slow=${ARASO_SLOW:-0}
sleep $((3 + slow))

field; xdotool type --delay 80 "dkssud hello "
expect "Korean and English per word" "안녕 hello "

field; xdotool type --delay 80 "githubdp dlTek."
expect "English with a particle, then Korean with a period" "github에 있다."

field; xdotool type --delay 80 "dkssud"; xdotool key Alt_R; xdotool type --delay 80 " "
expect "the right Alt tap switches the word" "dkssud "

field; xdotool type --delay 80 "dkssud "; xdotool key Alt_R
expect "and right after the word" "dkssud "

field; xdotool key Control_R; xdotool type --delay 80 "dkssud "; xdotool key Control_R; xdotool type --delay 80 "dkssud "
expect "the right Ctrl tap pauses" "dkssud 안녕 "

field; xdotool type --delay 80 "dkssud"; xdotool key Return; xdotool key Return
expect "Return confirms, a second one goes to the app" "안녕
"
# A Korean keyboard's 한/영 and 한자 keys (evdev KEY_HANGEUL, KEY_HANJA: X's Hangul, Hangul_Hanja).
field; xdotool type --delay 80 "dkssud"; xdotool key Hangul; xdotool type --delay 80 " "
expect "the 한/영 key switches the word" "dkssud "
field; xdotool key Hangul_Hanja; xdotool type --delay 80 "dkssud "; xdotool key Hangul_Hanja; xdotool type --delay 80 "dkssud "
expect "the 한자 key pauses" "dkssud 안녕 "

# vim's mode (scripts/vim sends it): in normal mode every key goes straight to the app.
field; araso-settings --vim normal; sleep 0.3; xdotool type --delay 80 "dkssud "
araso-settings --vim insert; sleep 0.3; xdotool type --delay 80 "dkssud "; araso-settings --vim off
expect "vim's normal mode passes keys, insert mode decides" "dkssud 안녕 "

echo '{"japanese": true}' > "$HOME/.config/araso/settings.json"; reload; sleep "$slow"
field; xdotool type --delay 80 "kyouha "; sleep $((1 + slow)); import -window root "$shots/linux-candidates.png"; xdotool key Return; sleep "$slow"
expect "Japanese: kanji from the card" "今日は"
echo '{}' > "$HOME/.config/araso/settings.json"; reload

# The settings window's Try Typing: typed through fcitx5's Qt module, the addon reports each word.
rm -f /tmp/settings-out.txt
ARASO_TYPING_OUT=/tmp/settings-out.txt araso-settings --settings typing >/tmp/settings.log 2>&1 &
settings_pid=$!
sleep $((3 + slow))
xdotool windowfocus --sync "$(xdotool search --class araso-settings | tail -1)" >/dev/null 2>&1
sleep 0.6
on "the settings window"
xdotool type --delay 80 "dkssud hello "
sleep 1.5
import -window root "$shots/linux-try-typing.png"
kill "$settings_pid" 2>/dev/null
got=$(cat /tmp/settings-out.txt 2>/dev/null)
if [ "$got" = "안녕 hello " ]; then echo "ok   the settings window (Qt) types through fcitx5"; else echo "FAIL the settings window (Qt): got \"$got\""; failures=$((failures + 1)); fi
echo "$failures failed"
exit "$failures"
