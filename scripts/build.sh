#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
output="${AMAPOANI_OUTPUT_DIR:-$root/build/preview}"
output="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve())' "$output")"
signer="${AMAPOANI_SIGN_IDENTITY:-}"
if [[ "$output" == "$root/build/preview" && -n "$signer" && "$signer" != "-" ]]; then
    echo "Choose a separate AMAPOANI_OUTPUT_DIR for a certificate-backed build." >&2
    exit 1
fi
if [[ "$output" == "$root/build/current" && -z "$signer" && -f "$root/work/signing/identity.sha1" ]]; then
    read -r signer < "$root/work/signing/identity.sha1"
fi
if [[ -z "$signer" || "$signer" == "-" ]]; then
    if [[ "$output" == "$root/build/current" ]]; then
        echo "Set up a signing identity before updating the installed app. Use AMAPOANI_OUTPUT_DIR for an ad hoc preview." >&2
        exit 1
    fi
    signer="-"
fi
export CARGO_TARGET_DIR="$root/work/build-core"
cargo=cargo
if [[ -x "$root/work/toolchains/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$root/work/toolchains/cargo" RUSTUP_HOME="$root/work/toolchains/rustup"
    cargo="$CARGO_HOME/bin/cargo"
fi
mkdir -p "$root/work"
"$cargo" build --locked --offline --release --manifest-path core/Cargo.toml
stage="$(mktemp -d "$root/work/amapoani-build.XXXXXX")"
trap 'rmdir "$stage" 2>/dev/null || true' EXIT
bundle="$stage/Amapoani.app"
mac="$bundle/Contents/MacOS"
frameworks="$bundle/Contents/Frameworks"
mkdir -p "$mac" "$frameworks"
mkdir -p "$bundle/Contents/Resources"
cp -R app/Resources/VoiceSamples "$bundle/Contents/Resources/"
cp -R app/Resources/Icons "$bundle/Contents/Resources/"
cp app/Resources/AppIcon.icns "$bundle/Contents/Resources/"
cp app/Info.plist "$bundle/Contents/Info.plist"
if [[ "$signer" == "-" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.ahampo.preview' \
        -c 'Set :CFBundleDisplayName Amapoani Preview' -c 'Delete :NSServices' "$bundle/Contents/Info.plist"
fi
whisper="$root/work/runtime/whisper"
sherpa="$root/work/runtime/sherpa"
for dylib in "$whisper"/build/bin/lib{whisper,ggml}*.dylib "$sherpa"/lib/lib{sherpa-onnx-c-api,onnxruntime}.dylib; do
    cp -P "$dylib" "$frameworks/"
done
clang++ -std=c++20 -O2 -mmacosx-version-min=14.0 -Wno-deprecated-declarations speech/worker.cpp \
  -I "$whisper/include" -I "$whisper/ggml/include" -I "$sherpa/include" \
  -L "$frameworks" -lwhisper -lsherpa-onnx-c-api -Wl,-rpath,@executable_path/../Frameworks \
  -o "$mac/ahampo-speech"
swiftc -O -target arm64-apple-macosx14.0 -module-cache-path work/preflight/apple-module-cache -import-objc-header app/Core.h \
  app/*.swift "$CARGO_TARGET_DIR/release/libahampo_core.a" -o "$mac/AHAMPO"
for dylib in "$frameworks/"*.dylib; do
    if [[ ! -L "$dylib" ]]; then codesign --force --sign "$signer" "$dylib"; fi
done
codesign --force --sign "$signer" "$mac/ahampo-speech"
codesign --force --sign "$signer" "$bundle"
python3 scripts/install-build.py "$bundle" "$output"
