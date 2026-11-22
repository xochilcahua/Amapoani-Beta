#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
bundle="${1:?Pass an ad hoc Amapoani preview bundle}"
output="${2:?Pass an absolute output ZIP path}"
[[ "$bundle" == /* && "$output" == /* && ! -e "$output" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == local.ahampo.preview ]]
/usr/bin/codesign -dvv "$bundle" 2>&1 | /usr/bin/grep -q 'Signature=adhoc'
stage="$(mktemp -d "$root/work/installer.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
package="$stage/Amapoani Installer"
mkdir -p "$package/Payload"
cp scripts/Install-Amapoani.command "$package/"
cp LICENSE BRAND.md NOTICE THIRD_PARTY.md "$package/"
cp -R licenses "$package/"
/usr/bin/ditto "$bundle" "$package/Payload/Amapoani.app"
app="$package/Payload/Amapoani.app"
cp app/Info.plist "$app/Contents/Info.plist"
cp LICENSE BRAND.md NOTICE THIRD_PARTY.md "$app/Contents/Resources/"
cp -R licenses "$app/Contents/Resources/"
rm "$app/Contents/Frameworks/libsherpa-onnx-c-api.dylib" "$app/Contents/Frameworks/libonnxruntime.dylib"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package" "$output"
