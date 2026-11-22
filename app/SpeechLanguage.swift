import Foundation
import NaturalLanguage

enum SpeechLanguage: UInt8, CaseIterable {
    case automatic, english, spanish

    static var preference: Self {
        let value = UserDefaults.standard.integer(forKey: Preference.language)
        return UInt8(exactly: value).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    var abbreviation: String {
        switch self {
        case .automatic: return "Auto"
        case .english: return "EN"
        case .spanish: return "ES"
        }
    }

    var next: Self {
        Self(rawValue: (rawValue + 1) % UInt8(Self.allCases.count))!
    }

    var tokenizerLanguage: NLLanguage { self == .spanish ? .spanish : .english }

    func forReading(_ text: String) -> Self {
        guard self == .automatic else { return self }
        let sample = String(text.prefix(2048))
        let shortPhrase = sample.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if ["hola", "gracias", "buenos días", "buenas tardes", "buenas noches"].contains(shortPhrase) { return .spanish }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let spanish = hypotheses[.spanish] ?? 0
        let alternative = hypotheses.filter { $0.key != .spanish }.values.max() ?? 0
        let threshold = sample.contains(where: { "¿¡".contains($0) }) ? 0.35 : 0.60
        return spanish >= threshold && spanish > alternative ? .spanish : .english
    }
}
