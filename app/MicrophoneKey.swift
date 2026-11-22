import Foundation

final class MicrophoneKey {
    enum Status: Equatable {
        case off, checking, active, problem(String)
    }

    enum Mapping: Equatable {
        case unavailable, empty, ownPair, other
    }

    private static let original: UInt64 = 51_539_607_759
    private static let f13: UInt64 = 30_064_771_176
    private static let match = #"{"Product":"Apple Internal Keyboard / Trackpad","PrimaryUsagePage":1,"PrimaryUsage":6}"#
    private static let ownershipKey = "ownsMicrophoneKeyMapping"
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "local.ahampo.microphone-key", qos: .userInitiated)

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func parse(_ output: String) -> Mapping {
        let lines = output.split(whereSeparator: \.isNewline)
        let rows = lines.filter {
            let columns = $0.split(whereSeparator: \.isWhitespace)
            return columns.count >= 2 && columns[1] == "UserKeyMapping" && UInt64(columns[0], radix: 16) != nil
        }
        guard rows.count == 1, let row = rows.first,
              let index = lines.firstIndex(of: row), let name = row.range(of: "UserKeyMapping") else { return .unavailable }
        let value = (String(row[name.upperBound...]) + lines.dropFirst(index + 1).joined()).filter { !$0.isWhitespace }
        switch value {
        case "(null)", "()": return .empty
        case "({HIDKeyboardModifierMappingDst=\(f13);HIDKeyboardModifierMappingSrc=\(original);})",
             "({HIDKeyboardModifierMappingSrc=\(original);HIDKeyboardModifierMappingDst=\(f13);})":
            return .ownPair
        default: return .other
        }
    }

    func configure(_ enabled: Bool, completion: @escaping (Status) -> Void) {
        queue.async { [self] in
            let status = enabled ? enable() : disable()
            DispatchQueue.main.async { completion(status) }
        }
    }

    func releaseOnQuit() {
        queue.sync { if defaults.bool(forKey: Self.ownershipKey) { _ = disable() } }
    }

    private func enable() -> Status {
        do {
            switch try mapping() {
            case .unavailable:
                return .problem("No supported built-in microphone key was found. Use the global shortcut.")
            case .other:
                return .problem("Your built-in keyboard already has a remap. Remove the conflicting remap or use the global shortcut.")
            case .ownPair:
                return .active
            case .empty:
                _ = try command("--set", #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\#(Self.original),"HIDKeyboardModifierMappingDst":\#(Self.f13)}]}"#)
                guard try mapping() == .ownPair else { return blocked }
                defaults.set(true, forKey: Self.ownershipKey)
                return .active
            }
        } catch { return blocked }
    }

    private func disable() -> Status {
        guard defaults.bool(forKey: Self.ownershipKey) else { return .off }
        do {
            if try mapping() == .ownPair {
                _ = try command("--set", #"{"UserKeyMapping":[]}"#)
                guard try mapping() != .ownPair else { return blocked }
            }
            defaults.removeObject(forKey: Self.ownershipKey)
            return .off
        } catch { return blocked }
    }

    private var blocked: Status {
        .problem("macOS didn't apply the keyboard change. See Setup Help or use the global shortcut.")
    }

    private func mapping() throws -> Mapping { Self.parse(try command("--get", "UserKeyMapping")) }

    private func command(_ operation: String, _ value: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--matching", Self.match, operation, value]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.featureUnsupported) }
        return String(decoding: data, as: UTF8.self)
    }
}
