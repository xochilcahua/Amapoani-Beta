# Microphone-key shortcut

The built-in microphone key sends the HID Voice Command usage. Holding Fn on a keyboard with Apple’s default function-row behavior sends F5 instead. Amapoani can optionally register F13 as a second shortcut. [Apple’s key remapping notes](https://developer.apple.com/library/archive/technotes/tn2450/) · [A similar Dictation-key mapping tested with Handy](https://github.com/cjpais/Handy/discussions/1026)

With Apple Dictation disabled, run `./scripts/map-microphone-key.sh enable` from the repository. Enable **Use the microphone key (F13)** under **Settings → Shortcuts**. While Amapoani runs, tapping the key shows or hides its idle capsule. Active playback and recording stay visible. Fn+F5 retains its normal function-key behavior. The regular Amapoani shortcut is available regardless of the remap.

On the configured Mac, the `local.amapoani.microphone-key` user LaunchAgent runs the same helper at login. The helper checks the built-in keyboard’s current map before writing and refuses to overwrite a different remap. Keep the checkout at the same path for this login item to find the helper.

To undo it, turn off the Amapoani checkbox. If the login item is installed, unload it with `launchctl bootout "gui/$(id -u)/local.amapoani.microphone-key"` and move `~/Library/LaunchAgents/local.amapoani.microphone-key.plist` to Trash. Run `./scripts/map-microphone-key.sh disable` to clear the active mapping. The helper clears only the exact mapping it configured.
