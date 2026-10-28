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

# App icon, regenerated only when the drawing script changes.
icon_png="build/AppIcon-1024.png"
if [[ ! -f Resources/AppIcon.icns || scripts/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  mkdir -p build
  swift scripts/make-icon.swift "$icon_png"
  iconset="build/AppIcon.iconset"
  rm -rf "$iconset" && mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
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
