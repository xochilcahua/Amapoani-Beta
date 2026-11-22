#!/bin/bash
set -euo pipefail

# Apple Internal Keyboard only. Voice Command (consumer 0xCF) becomes F13
# (keyboard 0x68). Fn+F5 already sends a different keyboard usage.
keyboard='{"Product":"Apple Internal Keyboard / Trackpad","PrimaryUsagePage":1,"PrimaryUsage":6}'
mapping='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":51539607759,"HIDKeyboardModifierMappingDst":30064771176}]}'
current="$(/usr/bin/hidutil property --matching "$keyboard" --get UserKeyMapping)"
has_our_mapping() {
    [[ "$(grep -c 'HIDKeyboardModifierMappingSrc' <<< "$current")" == 1 &&
       "$(grep -c 'HIDKeyboardModifierMappingDst' <<< "$current")" == 1 &&
       "$current" == *'HIDKeyboardModifierMappingSrc = 51539607759;'* &&
       "$current" == *'HIDKeyboardModifierMappingDst = 30064771176;'* ]]
}

case "${1:-}" in
    enable)
        if has_our_mapping; then exit 0; fi
        if ! grep -Eq '^([[:xdigit:]]+[[:space:]]+UserKeyMapping[[:space:]]+)?\(null\)[[:space:]]*$' <<< "$current" ||
           [[ "$(grep -c -E '^[[:xdigit:]]+[[:space:]]+UserKeyMapping' <<< "$current")" != 1 ]]; then
            echo "The built-in keyboard is unavailable or has a different mapping. Existing settings were preserved." >&2
            exit 1
        fi
        /usr/bin/hidutil property --matching "$keyboard" --set "$mapping"
        current="$(/usr/bin/hidutil property --matching "$keyboard" --get UserKeyMapping)"
        has_our_mapping
        ;;
    disable)
        if has_our_mapping; then
            /usr/bin/hidutil property --matching "$keyboard" --set '{"UserKeyMapping":[]}'
        fi
        ;;
    *)
        echo "Usage: $0 enable|disable" >&2
        exit 2
        ;;
esac
