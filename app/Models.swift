import AppKit
import CryptoKit

enum Model: String, CaseIterable {
    case reading, multilingualDictation, dictation

    var label: String {
        switch self {
        case .reading: return "Kokoro · EN / ES"
        case .multilingualDictation: return "Whisper multilingual"
        case .dictation: return "Whisper English-only (optional)"
        }
    }
    var filename: String {
        switch self {
        case .reading: return "kokoro-multi-lang-v1_0"
        case .multilingualDictation: return "ggml-small-q5_1.bin"
        case .dictation: return "ggml-small.en-q5_1.bin"
        }
    }
    var workerMode: String { self == .reading ? "reading" : "dictation" }
    var url: URL {
        let whisper = "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
        switch self {
        case .reading: return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2")!
        case .multilingualDictation: return URL(string: whisper + "87cd18b47b941d2f65d09981dad23bb7d0481c77/" + filename)!
        case .dictation: return URL(string: whisper + "5359861/" + filename)!
        }
    }
    var digest: String {
        switch self {
        case .reading: return "60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4"
        case .multilingualDictation: return "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .dictation: return "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"
        }
    }
}

final class Models {
    private let fm = FileManager.default
    private let compactPack = "kokoro-int8-multi-lang-v1_0"
    var root: URL { URL(fileURLWithPath: UserDefaults.standard.string(forKey: Preference.folder)!, isDirectory: true) }

    func roots() -> [URL] {
        let preferences = UserDefaults.standard
        let chosen = (preferences.stringArray(forKey: "modelSearchLocations") ?? []).map { URL(fileURLWithPath: $0) }
        let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub/models--ggerganov--whisper.cpp/snapshots")
        let snapshots = (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        return [root] + chosen + snapshots.sorted { $0.path < $1.path }
    }

    func location(_ model: Model) -> URL? {
        candidates(for: model).first
    }

    func candidates(for model: Model, separateVoice: Bool = false) -> [URL] {
        let detached = Set(UserDefaults.standard.stringArray(forKey: "detachedModels") ?? [])
        var seen = Set<String>()
        var result: [URL] = []
        for folder in roots() {
            var paths = [folder.appendingPathComponent(model.filename), folder]
            if model == .reading { paths.append(folder.appendingPathComponent(compactPack)) }
            for candidate in paths
            where superficiallyCompatible(model, candidate, separateVoice: separateVoice) {
                let path = candidate.resolvingSymlinksInPath().path
                if !detached.contains(path), seen.insert(path).inserted { result.append(candidate) }
            }
        }
        if model == .reading {
            return result.filter { isFullPrecision($0) } + result.filter { !isFullPrecision($0) }
        }
        return result
    }

    func isFullPrecision(_ pack: URL) -> Bool {
        fileSize(pack.appendingPathComponent("model.onnx")) == 325_560_556
    }

    func readingWeights(in pack: URL) -> URL {
        pack.appendingPathComponent(isFullPrecision(pack) ? "model.onnx" : "model.int8.onnx")
    }

    func verifiedSpanishPhonemes(in pack: URL) -> Bool {
        let data = pack.appendingPathComponent("espeak-ng-data")
        return [
            "es_dict": "3fa93e251eab80838a2d6207ee58c9c847270a65fe3fae98850e0185b5a2186c",
            "lang/roa/es": "966aa015ea5646d79f0ca4807cf5da7339aabd3782b55cfa5eb0d8c3fc8fc588"
        ].allSatisfy { (try? Self.hash(data.appendingPathComponent($0.key))) == $0.value }
    }

    func verifiedVoiceTable(in pack: URL) -> Bool {
        (try? Self.hash(pack.appendingPathComponent("voices.bin"))) ==
            "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29"
    }

    func verifiedLocation(_ model: Model, among candidates: [URL], separateVoice: Bool = false) -> URL? {
        candidates.first { verified(model, $0, separateVoice: separateVoice) }
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private func superficiallyCompatible(_ model: Model, _ path: URL, separateVoice: Bool) -> Bool {
        if model != .reading {
            return path.lastPathComponent == model.filename &&
                fileSize(path) == (model == .multilingualDictation ? 190_085_487 : 190_098_681)
        }
        return (isFullPrecision(path) || fileSize(path.appendingPathComponent("model.int8.onnx")) == 114_202_993) &&
            (separateVoice || fileSize(path.appendingPathComponent("voices.bin")) == 28_200_960) &&
            fileSize(path.appendingPathComponent("tokens.txt")) == 687 &&
            fm.fileExists(atPath: path.appendingPathComponent("espeak-ng-data/en_dict").path)
    }

    func verified(_ model: Model, _ path: URL, separateVoice: Bool = false) -> Bool {
        if model != .reading { return (try? Self.hash(path)) == model.digest }
        if !separateVoice && !verifiedVoiceTable(in: path) { return false }
        return [
            readingWeights(in: path).lastPathComponent: isFullPrecision(path)
                ? "b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11"
                : "75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e",
            "tokens.txt": "6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425",
            "espeak-ng-data/en_dict": "71bd330ba8a2e3e8076e631508208ef49449d6147c17b7bd2b4b1e1468292e35",
            "espeak-ng-data/phondata": "4e0288957874029a8c3c9f41a8f517ad4bf18127046decbdd4b9d1d6807ce3a3",
            "espeak-ng-data/phonindex": "3ca7b8fa3b42624e4b0f152707e7a39245fce569aa99ea47c055d9e622fcf0c4",
            "espeak-ng-data/phontab": "886f3fa402cb0ba73d483aa8ad000af47a6b7cc06293c75a97913fba68a530f6"
        ].allSatisfy { (try? Self.hash(path.appendingPathComponent($0.key))) == $0.value }
    }

    static func hash(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var digest = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func receipt(_ model: Model, at location: URL) -> URL {
        location.deletingLastPathComponent().appendingPathComponent(model == .reading && location.lastPathComponent == model.filename
            ? ".ahampo-reading-fp32" : ".ahampo-" + model.rawValue)
    }

    func owns(_ model: Model, at location: URL? = nil) -> Bool {
        let final = location ?? root.appendingPathComponent(model.filename)
        let compact = model == .reading && final.lastPathComponent == compactPack
        guard final.standardizedFileURL == root.appendingPathComponent(compact ? compactPack : model.filename).standardizedFileURL else { return false }
        let digest = compact ? "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653" : model.digest
        return (try? String(contentsOf: receipt(model, at: final), encoding: .utf8)) == digest &&
            fm.fileExists(atPath: final.path) && final.resolvingSymlinksInPath() == final.standardizedFileURL
    }

    func detach(_ location: URL) {
        let preferences = UserDefaults.standard
        var ignored = preferences.stringArray(forKey: "detachedModels") ?? []
        ignored.append(location.resolvingSymlinksInPath().path)
        preferences.set(ignored, forKey: "detachedModels")
    }

    func delete(_ model: Model, at location: URL) throws {
        guard owns(model, at: location) else { throw ModelError("The shared model has changed. Reopen Settings to check its location.") }
        try fm.removeItem(at: location)
        try fm.removeItem(at: receipt(model, at: location))
    }

    func installArchive(_ model: Model, from temporary: URL, in folder: URL) throws -> URL {
        guard try Self.hash(temporary) == model.digest else {
            throw ModelError("The downloaded file did not match its verified checksum.")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stage = folder.appendingPathComponent(".ahampo-staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let final = folder.appendingPathComponent(model.filename)
        if fm.fileExists(atPath: final.path) {
            guard verified(model, final) else { throw ModelError("A different file already occupies the model path.") }
            return final
        }
        let staged = stage.appendingPathComponent(model.filename)
        if model != .reading {
            try fm.copyItem(at: temporary, to: staged)
        } else {
            let archive = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                          arguments: ["-xjf", temporary.path, "-C", stage.path])
            archive.waitUntilExit()
            guard archive.terminationStatus == 0 else { throw ModelError("The Kokoro archive could not be opened.") }
        }
        guard verified(model, staged), model != .reading || verifiedSpanishPhonemes(in: staged) else {
            throw ModelError("The downloaded model set was incomplete.")
        }
        try fm.moveItem(at: staged, to: final)
        try model.digest.write(to: receipt(model, at: final),
                               atomically: true, encoding: .utf8)
        return final
    }

    func install(_ model: Model, completion: @escaping (Result<Void, Error>) -> Void) {
        let folder = root
        let task = URLSession(configuration: .ephemeral).downloadTask(with: model.url) { [self] temporary, response, error in
            let result = Result<URL, Error> {
                if let error { throw error }
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ModelError("The download did not complete.")
                }
                return try installArchive(model, from: temporary, in: folder)
            }
            DispatchQueue.main.async {
                completion(result.map { location in
                    let preferences = UserDefaults.standard
                    let ignored = preferences.stringArray(forKey: "detachedModels") ?? []
                    let path = location.resolvingSymlinksInPath().path
                    preferences.set(ignored.filter { $0 != path }, forKey: "detachedModels")
                })
            }
        }
        task.resume()
    }
}

struct ModelError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
