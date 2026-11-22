import Foundation

final class VoiceLibrary {
    private let models: Models
    private let prefs: UserDefaults
    private let fm = FileManager.default
    private let libraryKey = "enabledReadingVoices"
    private let ownedKey = "downloadedEnglishVoiceFiles" // Preserve receipts from earlier builds.

    init(models: Models, defaults: UserDefaults = .standard) {
        self.models = models
        self.prefs = defaults
    }

    var enabled: [ReadingVoice] {
        if let ids = prefs.array(forKey: libraryKey) as? [Int] {
            return ReadingVoice.allCases.filter { ids.contains(Int($0.rawValue)) }
        }
        let english = prefs.array(forKey: "enabledEnglishVoices") as? [Int] ??
            [Int(ReadingVoice.heart.rawValue), prefs.integer(forKey: Preference.voice)]
        return ReadingVoice.allCases.filter { $0 == .dora || ($0.language == .english && english.contains(Int($0.rawValue))) }
    }

    func selected(for language: SpeechLanguage) -> ReadingVoice? {
        let voices = enabled.filter { $0.language == language }
        let key = language == .spanish ? Preference.spanishVoice : Preference.voice
        return voices.first { Int($0.rawValue) == prefs.integer(forKey: key) } ?? voices.first
    }

    func select(_ voice: ReadingVoice) {
        if enabled.contains(voice) {
            prefs.set(Int(voice.rawValue), forKey: voice.language == .spanish ? Preference.spanishVoice : Preference.voice)
        }
    }

    private func managedFile(_ voice: ReadingVoice) -> URL {
        models.root.appendingPathComponent("kokoro-voices-v1").appendingPathComponent(voice.filename + ".bin")
    }

    func standalone(_ voice: ReadingVoice) -> URL? {
        for folder in models.roots() {
            for directory in ["kokoro-voices-v1", "voices", ""] {
                let url = folder.appendingPathComponent(directory).appendingPathComponent(voice.filename + ".bin")
                if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 522_240,
                   (try? Models.hash(url)) == voice.digest { return url }
            }
        }
        return nil
    }

    func add(_ voice: ReadingVoice, completion: @escaping (Result<Void, Error>) -> Void) {
        let target = managedFile(voice)
        let candidates = models.candidates(for: .reading)
        func finish(_ result: Result<Bool, Error>) {
            DispatchQueue.main.async { [self] in
                completion(result.map { owned in
                    if owned {
                        var paths = prefs.stringArray(forKey: ownedKey) ?? []
                        if !paths.contains(target.path) { paths.append(target.path) }
                        prefs.set(paths, forKey: ownedKey)
                    }
                    var list = enabled
                    if !list.contains(voice) { list.append(voice) }
                    prefs.set(list.map { Int($0.rawValue) }, forKey: libraryKey)
                })
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // A shared Sherpa pack already contains the catalog embeddings.
            if standalone(voice) != nil || models.verifiedLocation(.reading, among: candidates) != nil {
                finish(.success(false))
                return
            }
            let base = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/1939ad2a8e416c0acfeecc08a694d14ef25f2231/voices/"
            let url = URL(string: base + voice.filename + ".bin")!
            URLSession.shared.downloadTask(with: url) { [self] temporary, response, error in
                finish(Result {
                    if let error { throw error }
                    guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200,
                          try Models.hash(temporary) == voice.digest else {
                        throw ModelError("The voice download could not be verified. Try again.")
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) {
                        guard try Models.hash(target) == voice.digest else {
                            throw ModelError("Another file already occupies this voice’s location.")
                        }
                        return false
                    }
                    let staging = target.deletingLastPathComponent().appendingPathComponent(".voice-" + UUID().uuidString)
                    defer { try? fm.removeItem(at: staging) }
                    try fm.copyItem(at: temporary, to: staging)
                    try fm.moveItem(at: staging, to: target)
                    return true
                })
            }.resume()
        }
    }

    func owns(_ voice: ReadingVoice) -> Bool {
        let file = managedFile(voice)
        return (prefs.stringArray(forKey: ownedKey) ?? []).contains(file.path) &&
            file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL &&
            (try? Models.hash(file)) == voice.digest
    }

    func remove(_ voice: ReadingVoice) throws {
        let file = managedFile(voice)
        if owns(voice) { try fm.removeItem(at: file) }
        let paths = prefs.stringArray(forKey: ownedKey) ?? []
        prefs.set(paths.filter { $0 != file.path }, forKey: ownedKey)
        let remaining = enabled.filter { $0 != voice }
        prefs.set(remaining.map { Int($0.rawValue) }, forKey: libraryKey)
        if let next = selected(for: voice.language) { select(next) }
    }
}
