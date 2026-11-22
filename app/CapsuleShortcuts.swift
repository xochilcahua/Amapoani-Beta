import AppKit

enum CapsuleCommand: String, CaseIterable {
    case read, dictate, editDraft, copyDraft, clearDraft, toggleDraft

    var worksInEditor: Bool { self == .copyDraft || self == .clearDraft || self == .toggleDraft }

    var label: String {
        switch self {
        case .read: return "Read Aloud"
        case .dictate: return "Start Dictation"
        case .editDraft: return "Edit Draft"
        case .copyDraft: return "Copy Draft"
        case .clearDraft: return "Clear Draft"
        case .toggleDraft: return "Expand or Collapse Draft"
        }
    }

    fileprivate var defaultKey: String {
        switch self {
        case .read: return "s"
        case .dictate: return "d"
        case .editDraft: return "e"
        case .copyDraft: return "c"
        case .clearDraft: return "k"
        case .toggleDraft: return "t"
        }
    }
}

struct CapsuleShortcuts {
    enum Modifier: Int, CaseIterable {
        case control, option

        var title: String { self == .control ? "Control" : "Option" }
        var symbol: String { self == .control ? "⌃" : "⌥" }
        var flag: NSEvent.ModifierFlags { self == .control ? .control : .option }
    }

    static let keys = "abcdefghijklmnopqrstuvwxyz".map(String.init)
    static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let summonOptions = ["Option–Shift–Space", "Control–Shift–Space"]
    private static let modifierKey = "capsuleCommandModifier"
    private static let bindingsKey = "capsuleCommandKeys"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var modifier: Modifier {
        get { Modifier(rawValue: defaults.integer(forKey: Self.modifierKey)) ?? .control }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.modifierKey) }
    }

    private var bindings: [String: String] {
        let saved = defaults.dictionary(forKey: Self.bindingsKey) as? [String: String] ?? [:]
        var result: [String: String] = [:]
        var used = Set<String>()
        for command in CapsuleCommand.allCases {
            if let key = saved[command.rawValue], Self.keys.contains(key), used.insert(key).inserted {
                result[command.rawValue] = key
            }
        }
        for command in CapsuleCommand.allCases where result[command.rawValue] == nil {
            let key = ([command.defaultKey] + Self.keys).first { !used.contains($0) }!
            result[command.rawValue] = key
            used.insert(key)
        }
        return result
    }

    func key(for command: CapsuleCommand) -> String { bindings[command.rawValue] ?? command.defaultKey }

    func setKey(_ key: String, for command: CapsuleCommand) {
        guard Self.keys.contains(key) else { return }
        var updated = bindings
        guard !updated.contains(where: { $0.key != command.rawValue && $0.value == key }) else { return }
        updated[command.rawValue] = key
        defaults.set(updated, forKey: Self.bindingsKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.modifierKey)
        defaults.removeObject(forKey: Self.bindingsKey)
    }

    func hint(for command: CapsuleCommand) -> String { modifier.symbol + key(for: command).uppercased() }

    func command(for event: NSEvent) -> CapsuleCommand? {
        guard event.type == .keyDown, event.modifierFlags.intersection(Self.shortcutModifiers) == modifier.flag,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let bindings = bindings
        return CapsuleCommand.allCases.first { bindings[$0.rawValue] == key }
    }
}
