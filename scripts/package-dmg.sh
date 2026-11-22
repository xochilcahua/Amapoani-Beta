#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
sourceApp="${1:?Pass an ad hoc Amapoani preview bundle}"
image="${2:?Pass an absolute output DMG path}"
[[ "$sourceApp" == /* && "$image" == /* && ! -e "$image" && ! -L "$image" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$sourceApp/Contents/Info.plist")" == local.ahampo.preview ]]
signature="$(/usr/bin/codesign -dvv "$sourceApp" 2>&1)"
[[ "$signature" == *Signature=adhoc* ]]
scratch="$(mktemp -d "$root/work/dmg.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/Amapoani.app"
/usr/bin/ditto "$sourceApp" "$app"
cp app/Info.plist "$app/Contents/Info.plist"
cp LICENSE BRAND.md NOTICE THIRD_PARTY.md "$app/Contents/Resources/"
/usr/bin/ditto licenses "$app/Contents/Resources/licenses"
rm "$app/Contents/Frameworks/libsherpa-onnx-c-api.dylib" "$app/Contents/Frameworks/libonnxruntime.dylib"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
ln -s /Applications "$scratch/Applications"
/usr/bin/hdiutil create -fs HFS+ -format UDZO -volname Amapoani -srcfolder "$scratch" "$image"
