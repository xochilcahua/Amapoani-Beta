import Foundation

@main
struct MicrophoneKeyRegression {
    static func main() {
        typealias Mapping = MicrophoneKey.Mapping
        let parse = MicrophoneKey.parse
        let header = "RegistryID Key Value\n"
        let row = "100029139 UserKeyMapping "
        let pair = "{ HIDKeyboardModifierMappingDst = 30064771176; HIDKeyboardModifierMappingSrc = 51539607759; }"
        for (output, expected): (String, Mapping) in [
            (header + row + "(null)", .empty),
            (header + row + "(\n)\n", .empty),
            (header + row + "(\n" + pair + "\n)", .ownPair),
            (header + row + "(" + pair + ", { HIDKeyboardModifierMappingDst = 123; HIDKeyboardModifierMappingSrc = 456; })", .other),
            (header + row + "()", .empty),
            (header + row + "()\n123456 UserKeyMapping ()", .unavailable),
            (header, .unavailable),
            ("unrecognized", .unavailable)
        ] {
            precondition(parse(output) == expected)
        }
        print("Microphone key mapping parser passed empty, owned, conflict and unavailable cases")
    }
}
