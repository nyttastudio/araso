#!/bin/sh
# Real typing on Linux, from a Mac or Linux machine with Docker: builds the package in a Swift
# container on Ubuntu 22.04 (linux/scripts/build.sh, the settings window on Qt 5 as releases are),
# then installs it on a clean Ubuntu 24.04 with only fcitx5 and apps, and types into a GTK field and
# the settings window's Try Typing with xdotool on X (inside.sh), then on Wayland under a headless
# sway (wayland.sh). Screenshots land in build/linux/shots.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
arch=$(docker run --rm swift:6.2-noble uname -m)
here=linux/scripts/typing-test
docker build -q -t araso-linux-jammy -f $here/Dockerfile.jammy $here >/dev/null
docker build -q -t araso-linux-user -f $here/Dockerfile.user $here >/dev/null
docker build -q -t araso-linux-wayland -f $here/Dockerfile.wayland $here >/dev/null
docker volume create araso-linux-jammy >/dev/null
docker run --rm -v "$root":/src -v araso-linux-jammy:/build -w /src -e ARASO_SCRATCH=/build -e ARASO_QT=5 \
  araso-linux-jammy sh linux/scripts/build.sh --test
package="/src/build/linux/package/Araso-linux-$arch"
mkdir -p build/linux/shots
status=0
docker run --rm -v "$root":/src -e ARASO_SHOTS=/src/build/linux/shots araso-linux-user \
  sh /src/$here/inside.sh "$package" || status=1
docker run --rm -v "$root":/src -e ARASO_SHOTS=/src/build/linux/shots araso-linux-wayland \
  sh /src/$here/wayland.sh "$package" || status=1
exit $status
