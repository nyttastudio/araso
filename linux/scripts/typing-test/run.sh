#!/bin/sh
# Real typing on Linux, from a Mac or Linux machine with Docker: builds the package in a Swift
# container (linux/scripts/build.sh), then installs it on a clean Ubuntu with only fcitx5 and apps,
# and types into a GTK field and the settings window's Try Typing with xdotool (inside.sh).
# Screenshots land in build/linux/shots.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
arch=$(docker run --rm swift:6.2-noble uname -m)
docker build -q -t araso-linux-dev -f linux/scripts/typing-test/Dockerfile.dev linux/scripts/typing-test >/dev/null
docker build -q -t araso-linux-user -f linux/scripts/typing-test/Dockerfile.user linux/scripts/typing-test >/dev/null
docker volume create araso-linux-build >/dev/null
docker run --rm -v "$root":/src -v araso-linux-build:/build -w /src -e ARASO_SCRATCH=/build araso-linux-dev \
  sh linux/scripts/build.sh
mkdir -p build/linux/shots
docker run --rm -v "$root":/src -e ARASO_SHOTS=/src/build/linux/shots araso-linux-user \
  sh /src/linux/scripts/typing-test/inside.sh "/src/build/linux/package/Araso-linux-$arch"
