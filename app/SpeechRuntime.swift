import Foundation

final class SpeechRuntime {
    private static let pack = "sherpa-onnx-v1.13.8-osx-arm64-shared"
    private static let checksum = "b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56"
    private static let libraries = ["libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"]
    private let fm = FileManager.default
    private let bundle: Bundle
    private let support: URL

    init(bundle: Bundle = .main, support: URL? = nil) {
        self.bundle = bundle
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amapoani/Speech Runtime", isDirectory: true)
    }

    private var installed: URL { support.appendingPathComponent(Self.pack, isDirectory: true) }

    var libraryDirectory: URL? {
        if let bundled = bundle.privateFrameworksURL, complete(bundled) { return bundled }
        return complete(installed) ? installed : nil
    }

    private func complete(_ directory: URL) -> Bool {
        Self.libraries.allSatisfy {
            (try? directory.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func install(completion: @escaping (Result<Void, Error>) -> Void) {
        let source = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/" + Self.pack + ".tar.bz2")!
        URLSession(configuration: .ephemeral).downloadTask(with: source) { [self] temporary, response, error in
            let result = Result {
                if let error { throw error }
                guard let temporary, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ModelError("The speech runtime download did not complete.")
                }
                try unpack(temporary)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func unpack(_ archive: URL) throws {
        guard try Models.hash(archive) == Self.checksum else {
            throw ModelError("The speech runtime archive did not match its checksum.")
        }
        if complete(installed) { return }
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let stage = support.appendingPathComponent(".setup-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let paths = Self.libraries.map { Self.pack + "/lib/" + $0 }
        let tar = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                  arguments: ["-xjf", archive.path, "-C", stage.path] + paths)
        tar.waitUntilExit()
        let libraries = stage.appendingPathComponent(Self.pack + "/lib", isDirectory: true)
        guard tar.terminationStatus == 0, complete(libraries) else {
            throw ModelError("The speech runtime archive could not be unpacked.")
        }
        do { try fm.moveItem(at: libraries, to: installed) }
        catch { if !complete(installed) { throw error } }
    }
}
