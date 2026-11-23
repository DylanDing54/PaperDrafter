#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")"
bundle="PaperDrafter.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
cp Info.plist "$bundle/"
cp -R Resources/. "$bundle/Resources/"
# Some upgraded Command Line Tools installations leave a duplicate SwiftBridging map.
# Mask the obsolete copy for this compilation without changing the system SDK.
toolchain="$(xcode-select -p)/usr/include/swift"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
flags=()
if [[ -f "$toolchain/module.modulemap" && -f "$toolchain/bridging.modulemap" ]] && grep -q 'module SwiftBridging' "$toolchain/module.modulemap"; then
  touch "$scratch/empty.modulemap"
  cat > "$scratch/overlay.yaml" <<MAP
{ "version": 0, "roots": [{ "type": "file", "name": "$toolchain/module.modulemap", "external-contents": "$scratch/empty.modulemap" }] }
MAP
  flags=(-vfsoverlay "$scratch/overlay.yaml")
fi
swiftc -target "$(uname -m)-apple-macosx13.0" "${flags[@]}" -O -module-cache-path "${TMPDIR:-/tmp}/inktex-module-cache" Sources/*.swift -o "$bundle/MacOS/PaperDrafter" -framework Cocoa -framework PDFKit
codesign --force --sign - PaperDrafter.app
