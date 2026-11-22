# Amapoani

Amapoani is an offline read-aloud and dictation capsule for Apple Silicon Macs. It reads selected text or an editable draft with Kokoro, and transcribes speech with Whisper. The beta supports macOS 14 or later.

## Install the beta

Download `Amapoani-Installer-macos-arm64.zip` from the [beta release](https://github.com/xochilcahua/Amapoani-Beta/releases). Unzip it and open `Install-Amapoani.command`. The installer verifies and downloads the speech runtime, then places the app in `~/Applications`. Open Amapoani from Finder and use **Settings → Models → Download Missing Models**. The installer needs an internet connection for setup.

This beta is ad hoc signed and has no Apple notarization. macOS may ask for manual approval when you open it. [Apple's guidance for running downloaded apps](https://support.apple.com/en-us/102445)

## Build and open

Install the Xcode Command Line Tools, CMake, Rust with Cargo and Python 3. Run these commands from the repository root.

```sh
./scripts/bootstrap-macos.sh
./scripts/build.sh
open build/preview/Amapoani.app
```

The bootstrap downloads pinned speech runtimes and fetches Rust dependencies. The build produces a local ad hoc signed app. If a signed Amapoani installation is already running, quit it before testing the preview’s global shortcut. Use **Settings → Models → Download Missing Models** to set up speech. Existing compatible models can be reused from a shared folder.

## Use the capsule

The default global shortcut is **Option–Shift–Space**. The menu-bar **Show Capsule** command displays your configured shortcut. Click the speaker to read the current selection or the draft. To dictate into another app, place the caret there before summoning the capsule. Amapoani checks the original field again when you confirm insertion.

| Shortcut | Action |
| --- | --- |
| Control–S | Read aloud |
| Control–D | Start dictation |
| Control–E | Edit the draft |
| Control–C | Copy the whole draft or the transcript under review |
| Control–T | Expand or collapse the draft |
| Control–K | Clear the draft. Command–Z undoes the clear. |
| Return | Finish recording or insert the reviewed transcript |
| Escape | Cancel recording or discard the reviewed transcript |
| Command–Return | Insert while editing the reviewed transcript |

During review, the read, dictate and edit shortcuts act on the transcript. **Settings → Shortcuts** lets you change the action letters or switch their shared modifier to Option. The [optional microphone key](docs/microphone-key.md) can also toggle the capsule.

**Settings → Access** shows the macOS Accessibility and clipboard permissions used for browser integration. The internal editor works as a fallback when an app or field cannot be verified. Speech processing uses local files after setup. The app requests microphone access for dictation and the optional microphone check.

## Models and languages

Install **Whisper multilingual** for English and Spanish dictation. The underlying model handles additional languages and may recognize them in Auto. This beta exposes and tests English and Spanish. **Whisper English-only** is an optional fallback for an existing English-only installation. A single multilingual model is sufficient.

Kokoro reads in English and Spanish. Switch languages with the capsule's **Auto**, **EN** or **ES** control. **Settings → Speech** contains voice previews, speed and pause controls.

## Development

AppKit handles the capsule and macOS integration. Rust owns session state. A separate C++ process runs inference. See the [architecture notes](docs/architecture.md), [browser integration notes](docs/selection-integration.md) and [browser journeys](tests/journeys/README.md). Public CI runs the portable core checks. The optional macOS workflow builds and verifies the ad hoc app.

## License

The app source is available under [Apache 2.0](LICENSE). The Amapoani name and logos are reserved under the [brand terms](BRAND.md). See [third-party notices](THIRD_PARTY.md) for the speech engines and models.
