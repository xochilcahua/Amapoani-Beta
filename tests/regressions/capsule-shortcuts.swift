import AppKit

@main
struct ShortcutRegression {
    static func main() {
        let suite = "local.ahampo.shortcut-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = CapsuleShortcuts(defaults: defaults)

        func command(_ key: String, modifiers: NSEvent.ModifierFlags) -> CapsuleCommand? {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            return shortcuts.command(for: event)
        }

        precondition(shortcuts.hint(for: .dictate) == "⌃D")
        precondition(command("s", modifiers: .control) == .read)
        precondition(command("D", modifiers: .control) == .dictate)
        precondition(command("e", modifiers: .control) == .editDraft)
        precondition(command("S", modifiers: .shift) == nil)
        precondition(command("s", modifiers: [.control, .shift]) == nil)

        precondition(command("c", modifiers: .control) == .copyDraft)
        precondition(command("k", modifiers: .control) == .clearDraft)
        precondition(CapsuleCommand.clearDraft.worksInEditor)
        defaults.set(["read": "c", "dictate": "k"], forKey: "capsuleCommandKeys")
        precondition(command("c", modifiers: .control) == .read)
        precondition(command("k", modifiers: .control) == .dictate)
        precondition(Set(CapsuleCommand.allCases.map { shortcuts.key(for: $0) }).count == 5)
        shortcuts.reset()

        shortcuts.modifier = .option
        shortcuts.setKey("r", for: .read)
        shortcuts.setKey("r", for: .dictate)
        precondition(CapsuleShortcuts(defaults: defaults).hint(for: .read) == "⌥R")
        precondition(command("r", modifiers: .option) == .read)
        precondition(command("d", modifiers: .option) == .dictate)
        precondition(command("s", modifiers: .option) == nil)
        precondition(command("r", modifiers: .control) == nil)

        shortcuts.reset()
        precondition(command("s", modifiers: .control) == .read)
        precondition(command("r", modifiers: .option) == nil)
        print("Capsule shortcut defaults, remapping, and conflict checks passed")
    }
}
