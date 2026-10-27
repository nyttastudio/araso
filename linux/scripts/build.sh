#!/bin/sh
# Builds Araso for Linux on a Linux machine with Swift 6.2, fcitx5's development files, Qt 6 and
# CMake (docs/linux-port.md lists the packages), and stages the package install.sh installs:
#   build/linux/package/Araso-linux-<arch>/          install.sh, uninstall.sh and files/
#   build/linux/Araso-linux-<arch>.tar.gz            with --tar (what a release uploads)
# --test runs the addon's tests (typing through a fcitx5 instance) first.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
tar=0 test=0
for arg in "$@"; do
  case $arg in
    --tar) tar=1 ;;
    --test) test=1 ;;
    *) echo "usage: $0 [--test] [--tar]" >&2; exit 2 ;;
  esac
done
version=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist)
arch=$(uname -m)
absolute() { case $1 in /*) echo "$1" ;; *) echo "$root/$1" ;; esac; }
scratch=$(absolute "${ARASO_SCRATCH:-.build}")
out=$(absolute "${ARASO_OUT:-build/linux}")

# The Swift side, finding the runtime beside it once installed (users have no Swift toolchain).
swift build --scratch-path "$scratch" -c release --product ArasoBridge -Xlinker -rpath -Xlinker '$ORIGIN'
bridge="$scratch/release/libArasoBridge.so"
runtime="$out/runtime"
rm -rf "$runtime" && mkdir -p "$runtime"
ldd "$bridge" | awk '$3 ~ /\/swift\// { print $3 }' | while read -r lib; do cp -L "$lib" "$runtime/"; done
dictionary="$scratch/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary"

generator=""
command -v ninja >/dev/null 2>&1 && generator="-G Ninja"
# shellcheck disable=SC2086
cmake -S linux -B "$out/cmake" $generator -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DARASO_VERSION="$version" \
  -DARASO_BRIDGE="$bridge" -DARASO_RUNTIME="$runtime" -DDICTIONARY="$dictionary" \
  -DARASO_QT="${ARASO_QT:-}" -DARASO_TESTS=$( [ $test = 1 ] && echo ON || echo OFF )
cmake --build "$out/cmake" --parallel
if [ $test = 1 ]; then
  (cd "$out/cmake" && ctest --output-on-failure)
fi

# The package: everything under files/ as it goes under /, but the addon, whose folder install.sh finds.
package="$out/package/Araso-linux-$arch"
rm -rf "$package" && mkdir -p "$package/files/addon"
DESTDIR="$package/files" cmake --install "$out/cmake" >/dev/null
find "$package/files" -name araso.so -path '*fcitx5*' -exec mv {} "$package/files/addon/" \;
find "$package/files" -depth -type d -empty -delete
cp linux/scripts/install.sh linux/scripts/uninstall.sh "$package/"
echo "$version" > "$package/VERSION"
echo "staged $package ($version)"
if [ $tar = 1 ]; then
  tar -C "$out/package" -czf "$out/Araso-linux-$arch.tar.gz" "Araso-linux-$arch"
  cp "$out/Araso-linux-$arch.tar.gz" "$out/Araso-linux-$arch-$version.tar.gz"
  echo "packed $out/Araso-linux-$arch.tar.gz"
fi
