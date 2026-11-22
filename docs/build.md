# Build and test

Builds target Apple Silicon Macs with macOS 14 or later. Install Xcode Command Line Tools, CMake, Rust with Cargo, and Python 3.

```sh
./scripts/bootstrap-macos.sh
./scripts/build.sh
open build/preview/Amapoani.app
```

The bootstrap verifies and downloads pinned Whisper and Sherpa-ONNX dependencies. The local preview uses a separate bundle identifier. Quit the installed app before testing the preview’s global shortcuts, since both copies cannot register the same keys at once.

To package a public beta disk image from the ad hoc build:

```sh
./scripts/package-dmg.sh "$PWD/build/preview/Amapoani.app" "$PWD/build/Amapoani-macos-arm64.dmg"
hdiutil verify "$PWD/build/Amapoani-macos-arm64.dmg"
```

The disk image contains the app and an Applications shortcut. The app downloads the pinned reading runtime during setup. The ad hoc disk image has no Apple notarization.

## Checks

```sh
cargo build --locked --manifest-path core/Cargo.toml
python3 -B tests/acceptance/core_probe.py core/target/debug/libahampo_core.dylib
python3 -B tests/regressions/session.py core/target/debug/libahampo_core.dylib
python3 -B -m unittest discover -s tests/acceptance -p 'test_*.py'
swiftc app/MicrophoneKey.swift tests/regressions/microphone-key.swift -o /tmp/amapoani-mic-check
/tmp/amapoani-mic-check
```

GitHub runs the portable checks on push. The macOS build workflow can run on demand. See the [browser journeys](../tests/journeys/README.md) for live macOS checks and the [architecture notes](architecture.md) for details on the native app and speech workers.
