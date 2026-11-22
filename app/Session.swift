import Foundation

struct Presentation: Decodable {
    var phase = "standard"
    var readingView = "follow"
    var draft = ""
    var caret: Int?
    var snapshot: String?
    var preview = ""
    var recovery: String?
    var task: UInt64 = 0
    var expanded = false
    var visible = false
    var hiddenSince: UInt64?
    var offload = false

    var reading: Bool { ["loading", "playing", "playback_paused"].contains(phase) }
    var dictating: Bool { ["recording", "dictation_paused", "finishing"].contains(phase) }
}

final class Session {
    private let pointer = ahampo_session_create()!
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private(set) var state = Presentation()

    deinit { ahampo_session_destroy(pointer) }

    @discardableResult
    func apply(_ kind: String, _ values: [String: Any] = [:]) -> Presentation {
        var event = values
        event["kind"] = kind
        guard let payload = try? JSONSerialization.data(withJSONObject: event),
              let input = String(data: payload, encoding: .utf8),
              let output = input.withCString({ ahampo_session_apply(pointer, $0) }) else {
            preconditionFailure("Invalid session event: \(kind)")
        }
        defer { ahampo_string_free(output) }
        do {
            state = try decoder.decode(Presentation.self, from: Data(bytes: output, count: strlen(output)))
            return state
        } catch {
            preconditionFailure("Invalid session response")
        }
    }
}

enum Preference {
    static let keep = "keepLoaded"
    static let idle = "idleMinutes"
    static let reading = "readingMinutes"
    static let voice = "readingVoice"
    static let spanishVoice = "spanishReadingVoice"
    static let language = "speechLanguage"
    static let speed = "readingSpeedPercent"
    static let pauses = "readingPauses"
    static let dictation = "dictationMinutes"
    static let folder = "modelFolder"
    static let appearance = "appearance"
    static let iconStyle = "iconStyle"
    static let microphoneShortcut = "microphoneKeyShortcut"
    static let capsulePosition = "capsulePosition"
    static let capsuleExpansion = "capsuleExpansion"

    static func register() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Local Speech Models").path
        UserDefaults.standard.register(defaults: [
            keep: false, idle: 5, reading: 30, voice: Int(ReadingVoice.heart.rawValue), speed: 100, pauses: 0,
            dictation: 10, folder: root, appearance: 0,
            capsulePosition: CapsulePosition.bottomCenter.rawValue, capsuleExpansion: CapsuleExpansion.upward.rawValue
        ])
    }
}

func uptimeMS() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
