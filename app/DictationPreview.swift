import Foundation

struct Transcription {
    let text: String
    let language: SpeechLanguage?
}

struct DictationLanguage {
    let mode: SpeechLanguage
    private var detected: SpeechLanguage?
    var decoder: SpeechLanguage { detected ?? mode }

    mutating func observe(_ result: Transcription, frames: Int) {
        // Wait for a useful utterance before keeping Whisper's guess for the session.
        guard mode == .automatic, detected == nil, frames >= 48_000,
              result.text.split(whereSeparator: \.isWhitespace).count >= 3 else { return }
        detected = result.language
    }
}

struct DictationPreview {
    private static let window = 192_000
    private var chunks: [String] = []
    private var start = 0
    private var lastRequested = 0
    private var retried = false

    mutating func request(available: Int, pause: Bool) -> Range<Int>? {
        let end = min(available, start + Self.window)
        let interval = pause ? 16_000 : 48_000
        guard end > lastRequested, end - lastRequested >= interval || end == start + Self.window else { return nil }
        lastRequested = end
        return start..<end
    }

    mutating func receive(_ text: String?, for frames: Range<Int>) -> String? {
        guard let text else {
            if frames.count == Self.window, !retried {
                retried = true
                lastRequested = frames.lowerBound
            }
            return nil
        }
        retried = false
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if frames.count == Self.window {
            if !words.isEmpty { chunks.append(words) }
            start = frames.upperBound
            return chunks.joined(separator: " ")
        }
        return (words.isEmpty ? chunks : chunks + [words]).joined(separator: " ")
    }
}
