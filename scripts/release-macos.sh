#!/bin/zsh
# Publishes FastShot for macOS as a GitHub release that installed copies update from:
#
#   scripts/release-macos.sh 1.2.1 "Bu sürümde neler değişti"
#
# Builds and signs build/FastShot.app with that version, zips it as FastShot-macOS.zip and
# attaches it to the release macos-v<version> (created, or its zip replaced when it exists).
# Signing with the same certificate every time keeps the Screen Recording permission across updates.
set -euo pipefail
cd "${0:A:h:h}"

version=${1:-}
notes=${2:-"FastShot for macOS $version"}
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 'Kullanım: scripts/release-macos.sh 1.2.1 "Sürüm notları"'
  exit 1
fi
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"

swift test
FASTSHOT_VERSION=$version scripts/build-app.sh release

zip=build/FastShot-macOS.zip
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent build/FastShot.app "$zip"

tag="macos-v$version"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$zip" --clobber
else
  gh release create "$tag" "$zip" --title "FastShot for macOS $version" --notes "$notes"
fi
echo "Published $tag"
