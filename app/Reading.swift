import Foundation
import NaturalLanguage

// Speaker IDs in the verified Kokoro v1.0 voice table.
enum ReadingVoice: UInt8, CaseIterable {
    case heart = 3, bella = 2, michael = 16, emma = 21, dora = 28, alex = 29

    var language: SpeechLanguage {
        self == .dora || self == .alex ? .spanish : .english
    }

    var sample: String {
        language == .spanish
            ? "Cuando zarpa el último barco, el puerto se queda en silencio. ¿Alguien dejó la luz encendida?"
            : "When the last ferry pulls away, the harbor goes quiet. Did they leave the light on?"
    }

    var filename: String {
        switch self {
        case .heart: return "af_heart"
        case .bella: return "af_bella"
        case .michael: return "am_michael"
        case .emma: return "bf_emma"
        case .dora: return "ef_dora"
        case .alex: return "em_alex"
        }
    }

    var digest: String {
        switch self {
        case .heart: return "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"
        case .bella: return "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b"
        case .michael: return "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"
        case .emma: return "669fe0647f9dd04fcab92f1439a40eeb4c8b4ab1f82e4996fe3d918ce4a63b73"
        case .dora: return "f66ec66bd295acb18372e37008533a9a3228483ccd294e7538d5d9294ac9a532"
        case .alex: return "27809e9eafdcbcfff90a3016c697568676531de2a2c39cee29c96c7bd6b83e95"
        }
    }

    var label: String {
        switch self {
        case .heart: return "Heart (US English)"
        case .bella: return "Bella (US English)"
        case .michael: return "Michael (US English)"
        case .emma: return "Emma (UK English)"
        case .dora: return "Dora (Español)"
        case .alex: return "Alex (Español)"
        }
    }
}

struct ReadingOptions {
    let voice: ReadingVoice
    let speed: UInt8
    let compressed: Bool

    init(voice: ReadingVoice, defaults: UserDefaults = .standard) {
        self.voice = voice
        let speed = defaults.integer(forKey: Preference.speed)
        self.speed = UInt8((50...200).contains(speed) ? speed : 100)
        compressed = defaults.integer(forKey: Preference.pauses) == 1
    }
}

struct ReadingPhrase {
    let text: String
    let range: NSRange
    let endsParagraph: Bool

    static func split(_ source: String, language: SpeechLanguage = .english) -> [Self] {
        var phrases: [Self] = []

        func divide(_ range: Range<String.Index>) {
            var start = range.lowerBound
            while start < range.upperBound {
                let limit = source.index(start, offsetBy: 280, limitedBy: range.upperBound) ?? range.upperBound
                var end = limit
                if limit < range.upperBound {
                    let tail = source[source.index(start, offsetBy: 120)..<limit]
                    let clauseEnd = tail.indices.last {
                        ",;:—".contains(source[$0]) && source[source.index(after: $0)].isWhitespace
                    }
                    if let split = clauseEnd ?? tail.lastIndex(where: \.isWhitespace) {
                        end = source.index(after: split)
                    }
                }

                let part = start..<end
                start = end
                guard let last = source[part].lastIndex(where: { !$0.isWhitespace }) else { continue }
                let gap = source[source.index(after: last)...].prefix(while: \.isWhitespace)
                let paragraph = gap.endIndex != source.endIndex &&
                    (gap.contains("\u{2029}") || gap.lazy.filter(\.isNewline).prefix(2).count == 2)
                let text = source[part].trimmingCharacters(in: .whitespacesAndNewlines)
                let speech = String(String.UnicodeScalarView(text.unicodeScalars.filter {
                    $0.value != 0 && $0.value != 0x00AD && $0.value != 0xFEFF
                }))
                if !speech.isEmpty {
                    phrases.append(Self(text: speech, range: NSRange(part, in: source), endsParagraph: paragraph))
                }
            }
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = source
        tokenizer.setLanguage(language.tokenizerLanguage)
        var start = source.startIndex
        tokenizer.enumerateTokens(in: start..<source.endIndex) { range, _ in
            divide(start..<range.upperBound)
            start = range.upperBound
            return true
        }
        divide(start..<source.endIndex)
        return phrases
    }
}
