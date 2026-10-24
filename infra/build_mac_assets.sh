#!/bin/bash
# Regenerates src/chrome/app/theme/chromium/mac/Assets.car with the Alacrium app icon (needs Xcode's actool, run on macOS).
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONS="${ROOT}/logos/NEW/mac/gen/app"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

SET="${WORK}/Assets.xcassets/AppIcon.appiconset"
mkdir -p "${SET}"
echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > "${WORK}/Assets.xcassets/Contents.json"

entries=""
# <size> <scale> <source png>: macOS icon slots, each backed by the Alacrium PNG of the matching pixel size
while read -r size scale src; do
	cp "${ICONS}/${src}" "${SET}/${src}"
	entries+="{ \"filename\" : \"${src}\", \"idiom\" : \"mac\", \"scale\" : \"${scale}\", \"size\" : \"${size}\" },"
done <<'SLOTS'
16x16 1x icon_16x16.png
16x16 2x icon_16x16@2x.png
32x32 1x icon_32x32.png
32x32 2x icon_32x32@2x.png
128x128 1x icon_128x128.png
128x128 2x icon_128x128@2x.png
256x256 1x icon_256x256.png
256x256 2x icon_256x256@2x.png
512x512 1x icon_512x512.png
512x512 2x icon_512x512@2x.png
SLOTS
echo "{ \"images\" : [ ${entries%,} ], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }" > "${SET}/Contents.json"

xcrun actool --output-format human-readable-text --warnings --platform macosx --minimum-deployment-target 13.0 \
	--app-icon AppIcon --output-partial-info-plist "${WORK}/partial.plist" --compile "${WORK}" "${WORK}/Assets.xcassets"
cp "${WORK}/Assets.car" "${ROOT}/src/chrome/app/theme/chromium/mac/Assets.car"
