#!/bin/zsh
# Builds build/FastShot.app. Usage: scripts/build-app.sh [release|debug] [--install]
# --install copies the app to /Applications (or ~/Applications) and launches it.
set -euo pipefail
cd "${0:A:h:h}"

configuration=${1:-release}
install=false
[[ "${2:-}" == "--install" || "${1:-}" == "--install" ]] && install=true
[[ "$configuration" == "--install" ]] && configuration=release

swift build -c "$configuration" --product FastShot
binary_dir=$(swift build -c "$configuration" --show-bin-path)

app="build/FastShot.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/FastShot" "$app/Contents/MacOS/FastShot"
cp Resources/Info.plist "$app/Contents/Info.plist"
# FASTSHOT_VERSION=1.2.3 stamps a release version (the build number follows it: 1.2.3 → 10203).
if [[ -n "${FASTSHOT_VERSION:-}" ]]; then
  parts=(${(s:.:)FASTSHOT_VERSION})
  plutil -replace CFBundleShortVersionString -string "$FASTSHOT_VERSION" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$(( parts[1] * 10000 + parts[2] * 100 + parts[3] ))" "$app/Contents/Info.plist"
fi

# App icon from the shared logo (Resources/AppIcon.png, the same one FastShot for Windows uses),
# regenerated only when the logo changes.
logo="Resources/AppIcon.png"
if [[ ! -f Resources/AppIcon.icns || "$logo" -nt Resources/AppIcon.icns ]]; then
  iconset="build/AppIcon.iconset"
  rm -rf "$iconset" && mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$logo" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$logo" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Screen Recording permission across rebuilds;
# ad-hoc signatures change every build, so macOS would ask again each time.
identity=${FASTSHOT_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
if [[ -n "$identity" ]]; then
  codesign --force --deep --timestamp=none --sign "$identity" "$app"
  echo "Signed with: $identity"
else
  codesign --force --deep --sign - "$app"
  echo "Signed ad-hoc (Screen Recording permission may need re-granting after rebuilds)"
fi

echo "Built $app"

if $install; then
  destination="/Applications"
  [[ -w "$destination" ]] || destination="$HOME/Applications"
  mkdir -p "$destination"
  pkill -x FastShot 2>/dev/null || true
  sleep 0.5
  rm -rf "$destination/FastShot.app"
  ditto "$app" "$destination/FastShot.app"
  open "$destination/FastShot.app"
  echo "Installed to $destination/FastShot.app"
fi
