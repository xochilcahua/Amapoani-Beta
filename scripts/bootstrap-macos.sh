#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
    echo "This bootstrap prepares an Apple Silicon Mac build." >&2; exit 1;
}

runtime="$root/work/runtime"
mkdir -p "$runtime"
scratch="$(mktemp -d "$runtime/bootstrap.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

archive() {
    local url="$1" hash="$2" name="$3"
    if [[ -f "$runtime/$name" ]]; then
        cp "$runtime/$name" "$scratch/$name"
    else
        curl --fail --location --show-error --silent "$url" --output "$scratch/$name"
    fi
    (cd "$scratch" && printf '%s  %s\n' "$hash" "$name" | shasum -a 256 -c -)
}

if [[ ! -f "$runtime/whisper/include/whisper.h" ]]; then
    archive https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz \
        ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720 whisper.tar.gz
    mkdir "$scratch/whisper"
    tar -xzf "$scratch/whisper.tar.gz" --strip-components 1 -C "$scratch/whisper"
    mv "$scratch/whisper" "$runtime/whisper"
fi

if [[ ! -f "$runtime/whisper/build/bin/libwhisper.dylib" ]]; then
    cmake="${AMAPOANI_CMAKE:-cmake}"
    if [[ -x "$runtime/cmake-env/bin/cmake" && -z "${AMAPOANI_CMAKE:-}" ]]; then
        cmake="$runtime/cmake-env/bin/cmake"
    fi
    "$cmake" -S "$runtime/whisper" -B "$runtime/whisper/build" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
        -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
        -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_METAL=ON
    "$cmake" --build "$runtime/whisper/build" --config Release --parallel --target whisper
fi

if [[ ! -f "$runtime/sherpa/lib/libsherpa-onnx-c-api.dylib" ]]; then
    archive https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2 \
        b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56 sherpa-arm64.tar.bz2
    mkdir "$scratch/sherpa"
    tar -xjf "$scratch/sherpa-arm64.tar.bz2" --strip-components 1 -C "$scratch/sherpa"
    mv "$scratch/sherpa" "$runtime/sherpa"
fi

cargo=cargo
if [[ -x "$root/work/toolchains/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$root/work/toolchains/cargo" RUSTUP_HOME="$root/work/toolchains/rustup"
    cargo="$CARGO_HOME/bin/cargo"
fi
"$cargo" fetch --locked --manifest-path core/Cargo.toml
