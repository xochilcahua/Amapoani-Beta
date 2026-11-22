#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo "Amapoani requires an Apple Silicon Mac." >&2
    exit 1
}
here="$(cd "$(dirname "$0")" && pwd -P)"
destination="${AMAPOANI_INSTALL_DIR:-$HOME/Applications}"
app="$destination/Amapoani.app"
if [[ -e "$app" || -L "$app" ]]; then
    echo "Amapoani already exists at $app. Move that copy aside to install this build." >&2
    exit 1
fi
mkdir -p "$destination"
scratch="$(mktemp -d "$destination/.amapoani-install.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

pack=sherpa-onnx-v1.13.8-osx-arm64-shared
archive="$scratch/runtime.tar.bz2"
echo "Downloading the speech runtime…"
/usr/bin/curl --proto '=https' --tlsv1.2 --fail --location --show-error --silent \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/$pack.tar.bz2" -o "$archive"
(cd "$scratch" && printf '%s  runtime.tar.bz2\n' 'b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56' | /usr/bin/shasum -a 256 -c -)
/usr/bin/tar -xjf "$archive" -C "$scratch" "$pack/lib/libsherpa-onnx-c-api.dylib" "$pack/lib/libonnxruntime.dylib"

/usr/bin/ditto "$here/Payload/Amapoani.app" "$scratch/Amapoani.app"
bundle="$scratch/Amapoani.app"
for name in libsherpa-onnx-c-api libonnxruntime; do
    lib="$bundle/Contents/Frameworks/$name.dylib"
    cp "$scratch/$pack/lib/$name.dylib" "$lib"
    /usr/bin/codesign --force --sign - "$lib"
done
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
/bin/mv -n "$bundle" "$destination"
[[ ! -e "$bundle" ]] || { echo "Amapoani appeared at the destination during setup." >&2; exit 1; }
echo "Installed Amapoani at $app. Open it from Finder and use Settings → Models for speech setup."
