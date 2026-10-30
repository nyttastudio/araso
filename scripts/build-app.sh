#!/bin/zsh
# Builds build/Araso.app from the SwiftPM product, with its data files in
# Contents/Resources (the kana and text trigrams, Korean and English data, AzooKey's Japanese
# dictionary, the menu icon, third-party notices), then checks the
# bundle can actually load them with `Araso --selftest`.
#
#   scripts/build-app.sh                               this Mac's architecture
#   ARASO_ARCHS="arm64 x86_64" scripts/build-app.sh   universal (release.sh)
#   ARASO_APP_SIGN=<identity or hash> scripts/build-app.sh   that identity ("-": ad hoc)
set -euo pipefail
setopt extended_glob
cd "${0:A:h}/.."

archs=(${=ARASO_ARCHS:-})
flags=()
for arch in $archs; do flags+=(--arch $arch); done
swift build -c release --product Araso $flags
bin=$(swift build -c release --product Araso $flags --show-bin-path)
app=build/Araso.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Araso" "$app/Contents/MacOS/Araso"
cp Resources/Info.plist "$app/Contents/Info.plist"
# The input source's name in System Settings comes from these, not Info.plist.
cp -R Resources/*.lproj "$app/Contents/Resources/"
data=Sources/ArasoCore/Data
cp $data/kana_trigrams.txt $data/text_trigrams.txt $data/korean_syllables.txt $data/korean_words.txt $data/korean_vocabulary.txt $data/english_words.txt $data/english_acronyms.txt "$app/Contents/Resources/"
dictionary=.build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary
[[ -d "$dictionary" ]] || { echo "missing $dictionary (swift package resolve)"; exit 1; }
cp -R "$dictionary" "$app/Contents/Resources/Dictionary"
swift scripts/make-icon.swift "$app/Contents/Resources/Araso.tiff"
# The pause indicator under the caret (PauseHUD) shows the same mark, struck through while paused.
swift scripts/make-icon.swift --slash "$app/Contents/Resources/ArasoPaused.tiff"

# Licenses of everything compiled or copied into the app (MIT and Apache-2.0 ask for them
# to travel with the binary). A dependency without a license file stops the build.
notices="$app/Contents/Resources/ThirdPartyNotices.txt"
section() { printf '\n\n==== %s ====\n\n' "$1" >> "$notices"; cat "$2" >> "$notices"; }
print -r -- "Araso includes the following third-party software and data." > "$notices"
for checkout in .build/checkouts/*(/); do
  license=( $checkout/(#i)(license|copying)*(N.) )
  [[ -n "$license" ]] || { echo "no license file in $checkout"; exit 1; }
  section "${checkout:t} (Swift package)" "$license[1]"
done
section "llama.cpp (linked through AzooKeyKanaKanjiConverter)" scripts/third-party/llama.cpp-LICENSE
section "azooKey dictionary (Contents/Resources/Dictionary)" "${dictionary:h}/LICENSE"
section "Tatoeba (kana, written-Japanese, Korean syllable and word models)" scripts/third-party/tatoeba.txt
section "SCOWL (english_words.txt, english_acronyms.txt)" scripts/third-party/scowl-Copyright
section "FrequencyWords (korean_vocabulary.txt)" scripts/third-party/frequencywords.txt
# Signed with an identity when there is one: ARASO_APP_SIGN, else this keychain's Apple
# Development identity (a free Apple ID in Xcode gives one), else its Developer ID Application.
# After a reinstall swaps the executable, macOS starts an ad hoc copy no more (imklaunchagent:
# LaunchInputMethod() Error, status=-50) until the source is re-added in System Settings or the
# user logs out; a copy signed with any identity starts again on its own. By hash, since a
# keychain can hold two certificates of one name.
sign=${ARASO_APP_SIGN:-}
if [[ -z $sign ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for kind in "Apple Development" "Developer ID Application"; do
    sign=$(print -r -- "$identities" | awk -v k="\"$kind:" 'index($0, k) { print $2; exit }')
    [[ -n $sign ]] && break
  done
fi
if [[ -n $sign && $sign != - ]]; then
  codesign --force --options runtime --sign "$sign" "$app"
  echo "signed with $(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
  codesign --force --sign - "$app"
  echo "signed ad hoc"
fi

"$app/Contents/MacOS/Araso" --selftest
# The Intel half too, through Rosetta.
if (( ${archs[(Ie)x86_64]} )) && [[ $(uname -m) == arm64 ]]; then arch -x86_64 "$app/Contents/MacOS/Araso" --selftest; fi
# Running it registered this copy with LaunchServices: macOS could then pick it, not the
# installed one, when it launches the input method, and nothing starts.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
echo "built $app"
