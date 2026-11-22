import AVFoundation
import Foundation

final class Worker {
    private let queue = DispatchQueue(label: "local.ahampo.speech")
    private let proc = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var startupError: Error?
    private var hasSpanishPhonemes = false

    let voiceFile: URL?
    let model: Model

    init(model: Model, candidates: [URL], models: Models, voiceFile: URL? = nil) {
        self.model = model
        self.voiceFile = voiceFile
        queue.async { [self] in
            do {
                guard let location = models.verifiedLocation(model, among: candidates, separateVoice: voiceFile != nil) else {
                    throw ModelError("The installed model is incomplete or damaged.")
                }
                proc.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("ahampo-speech")
                guard let libraries = models.runtime.libraryDirectory else {
                    throw ModelError("Set up speech in Settings → Models.")
                }
                if libraries.standardizedFileURL != Bundle.main.privateFrameworksURL?.standardizedFileURL {
                    var environment = ProcessInfo.processInfo.environment
                    environment["DYLD_LIBRARY_PATH"] = libraries.path
                    proc.environment = environment
                }
                proc.arguments = [model.workerMode, location.path]
                if model == .reading {
                    let weights = models.readingWeights(in: location)
                    hasSpanishPhonemes = models.verifiedSpanishPhonemes(in: location)
                    proc.arguments?.append(weights.path)
                    if let voiceFile { proc.arguments?.append(voiceFile.path) }
                }
                proc.standardInput = input
                proc.standardOutput = output
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                guard try response() == Data("ready".utf8) else { throw ModelError("The speech engine could not load its model.") }
            } catch { startupError = error }
        }
    }

    deinit {
        if proc.isRunning { proc.terminate() }
    }

    func shutdown() {
        if proc.isRunning { proc.terminate() }
        queue.async { [self] in
            if proc.isRunning { proc.terminate() }
        }
    }

    func ask(_ data: Data, spanishReading: Bool = false, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            let result = Result {
                if let startupError { throw startupError }
                if spanishReading && !hasSpanishPhonemes {
                    throw ModelError("Kokoro is missing Spanish pronunciation files. Install the complete pack in Settings.")
                }
                guard proc.isRunning else { throw ModelError("The speech engine closed.") }
                var size = UInt32(data.count).littleEndian
                try input.fileHandleForWriting.write(contentsOf: Data(bytes: &size, count: 4))
                try input.fileHandleForWriting.write(contentsOf: data)
                return try response()
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func speak(_ phrase: ReadingPhrase, with options: ReadingOptions, completion: @escaping (Result<Data, Error>) -> Void) {
        let flags: UInt8 = (phrase.endsParagraph ? 1 : 0) | (options.compressed ? 2 : 0)
        var data = Data([0, 255, options.voice.rawValue, flags, options.speed])
        data.append(contentsOf: phrase.text.utf8)
        ask(data, spanishReading: options.voice.language == .spanish, completion: completion)
    }

    func transcribe(_ audio: Data, language: SpeechLanguage, completion: @escaping (Result<Transcription, Error>) -> Void) {
        var request = Data([language.rawValue])
        request.append(audio)
        ask(request) { reply in
            completion(reply.flatMap { data in
                guard let status = data.first, let recognized = SpeechLanguage(rawValue: status) else {
                    let message = data.first == 3 ? "Install verified bilingual Whisper in Settings." :
                        "Whisper returned an invalid response."
                    return .failure(ModelError(message))
                }
                return .success(Transcription(text: String(decoding: data.dropFirst(), as: UTF8.self),
                                              language: recognized == .automatic ? nil : recognized))
            })
        }
    }

    private func response() throws -> Data {
        let header = try read(4)
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length <= 64 * 1024 * 1024 else { throw ModelError("The engine returned an invalid response.") }
        return try read(length)
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let bytes = try output.fileHandleForReading.read(upToCount: count - data.count), !bytes.isEmpty else {
                throw ModelError("The speech engine stopped unexpectedly.")
            }
            data.append(bytes)
        }
        return data
    }
}

final class Capture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var frames: [Float] = []
    private var tap = false
    var maximumFrames = 16_000 * 600

    var frameCount: Int { lock.withLock { frames.count } }

    func reset() {
        pause()
        lock.withLock { frames = [] }
    }

    func resume() throws {
        guard !tap else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ModelError("No microphone is available.") }
        let scale = format.sampleRate / 16000
        let limit = maximumFrames
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channel = channels[0]
            self.lock.withLock {
                let size = min(limit - self.frames.count, Int(Double(count) / scale))
                for index in 0..<max(0, size) {
                    self.frames.append(channel[min(count - 1, Int(Double(index) * scale))])
                }
            }
        }
        tap = true
        do { try engine.start() }
        catch { pause(); throw error }
    }

    func pause() {
        if tap {
            engine.inputNode.removeTap(onBus: 0)
            tap = false
        }
        engine.stop()
        engine.reset()
    }

    func data(in range: Range<Int>? = nil) -> Data {
        lock.withLock {
            frames.withUnsafeBufferPointer { buffer in
                let start = range?.lowerBound ?? 0
                let end = min(buffer.count, range?.upperBound ?? buffer.count)
                guard start >= 0, end > start, let samples = buffer.baseAddress else { return Data() }
                return Data(bytes: samples.advanced(by: start), count: (end - start) * MemoryLayout<Float>.stride)
            }
        }
    }
}

final class Track {
    struct Chunk {
        let range: NSRange
        let start: Double
        let buffer: AVAudioPCMBuffer
        var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var origin = 0.0
    private var phase = UUID()
    private var playedTo = 0.0
    private(set) var chunks: [Chunk] = []
    var finishedGenerating = false
    var onEnd: (() -> Void)?

    var end: Double { chunks.last.map { $0.start + $0.duration } ?? 0 }
    var position: Double {
        guard node.isPlaying, let time = node.lastRenderTime, time.isSampleTimeValid || time.isHostTimeValid,
              let player = node.playerTime(forNodeTime: time), player.isSampleTimeValid, player.sampleRate > 0 else {
            return min(end, playedTo)
        }
        return min(end, origin + Double(player.sampleTime) / player.sampleRate)
    }

    init() { engine.attach(node) }

    func append(data: Data, range: NSRange, cap: Double) throws -> Bool {
        guard data.count > 4, (data.count - 4) % 4 == 0 else { return false }
        let rate = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard rate >= 8000, rate <= 96000,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) else { return false }
        let length = min((data.count - 4) / 4, max(0, Int((cap - end) * Double(rate))))
        guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(length)),
              let samples = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = UInt32(length)
        _ = data.withUnsafeBytes { bytes in
            memcpy(samples, bytes.baseAddress!.advanced(by: 4), length * 4)
        }
        let chunk = Chunk(range: range, start: end, buffer: buffer)
        if self.format == nil {
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        chunks.append(chunk)
        queue(chunk.buffer, through: chunk.start + chunk.duration)
        return true
    }

    private func queue(_ buffer: AVAudioPCMBuffer, through: Double) {
        let generation = phase
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, phase == generation else { return }
                playedTo = through
                if finishedGenerating && through >= end { onEnd?() }
            }
        }
    }

    func play() throws {
        guard format != nil else { return }
        if finishedGenerating && playedTo >= end {
            onEnd?()
            return
        }
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    func pause() {
        playedTo = position
        node.pause()
        engine.pause()
    }

    func seek(_ time: Double, resume: Bool) throws {
        phase = UUID()
        node.stop()
        origin = min(max(0, time), end)
        playedTo = origin
        for chunk in chunks where chunk.start + chunk.duration > origin {
            let skipped = max(0, Int((origin - chunk.start) * chunk.buffer.format.sampleRate))
            let length = Int(chunk.buffer.frameLength) - skipped
            if skipped == 0 {
                queue(chunk.buffer, through: chunk.start + chunk.duration)
            } else if length > 0,
                      let trimmed = AVAudioPCMBuffer(pcmFormat: chunk.buffer.format, frameCapacity: UInt32(length)) {
                trimmed.frameLength = UInt32(length)
                memcpy(trimmed.floatChannelData![0], chunk.buffer.floatChannelData![0].advanced(by: skipped), length * 4)
                queue(trimmed, through: chunk.start + chunk.duration)
            }
        }
        if resume { try play() } else { engine.pause() }
    }

    func stop() {
        phase = UUID()
        node.stop()
        engine.stop()
        chunks.removeAll()
        format = nil
    }
}
