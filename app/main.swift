import AppKit
import AVFoundation

private enum ReadingSource: String {
    case selection = "Reading selected text"
    case draft = "Reading draft"
    case transcript = "Reading transcript"
    case preview = "Voice preview"
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let session = Session()
    private let desktop = Desktop()
    private let models = Models()
    private lazy var voices = VoiceLibrary(models: models)
    private let capture = Capture()
    private var workers: [Model: Worker] = [:]
    private var refreshReadingWorker = false
    private let panel = CapsulePanel(capsuleFrame: NSRect(x: 0, y: 0, width: 560, height: 64))
    private let capsule = CapsuleView()
    private var settings: Settings?
    private var statusItem: NSStatusItem?
    private var shortcut: Shortcut?
    private var launched = false
    private var notice = "" { didSet { noticeTimer?.invalidate(); noticeTimer = nil } }
    private var noticeTimer: Timer?
    private var readRequest: Desktop.Request? {
        didSet { oldValue?.cancel() }
    }
    private var deliveryRequest: Desktop.Request? {
        didSet { oldValue?.cancel() }
    }
    private var dictationRequest: UUID?
    private var invocationID: UUID?
    private var invocationTarget: DictationTarget?
    private var capsuleAnchor: CGPoint?
    private var appliedFrame: NSRect?
    private var appliedRowOffset: CGFloat = 0
    private var dragSettlement: Timer?
    private var source: ReadingSource?
    private var hideAfterPreview = false
    private var destination = DictationTarget.draft
    private var reviewTarget = DictationTarget.draft
    private var editingTranscript = false
    private var track: Track?
    private var phrases: [ReadingPhrase] = []
    private var pendingSeek: Int?
    private var readingCap = 1800.0
    private var clock: Timer?
    private var idle: Timer?
    private var dictationPreview = DictationPreview()
    private var dictationLanguage = DictationLanguage(mode: .automatic)
    private var previewBusy = false
    private var checking = false
    private var micCheckID = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Preference.register()
        NSApp.setActivationPolicy(.accessory)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = capsule
        panel.delegate = self
        capsule.autoresizingMask = [.width, .height]
        panel.escape = { [weak self] in self?.escape() }
        panel.confirm = { [weak self] in self?.confirmDictation() ?? false }
        panel.copyTranscript = { [weak self] in
            guard let self, readyTranscript != nil else { return false }
            copyCurrentText()
            return true
        }
        panel.onCommand = { [weak self] command in self?.handle(command) }
        capsule.onAction = { [weak self] in self?.act($0) }
        capsule.onDraft = { [weak self] text, caret in
            var request: [String: Any] = ["text": text]
            if let caret { request["caret"] = caret }
            self?.session.apply("draft", request)
        }
        capsule.onSeek = { [weak self] time in self?.move(to: time) }
        capsule.onPhrase = { [weak self] offset in self?.seekPhrase(at: offset) }
        capsule.onTranscript = { [weak self] text in self?.session.apply("edit_recovery", ["text": text]) }
        let previewBesideInstalledApp = Bundle.main.bundleIdentifier == "local.ahampo.preview" &&
            !NSRunningApplication.runningApplications(withBundleIdentifier: "local.ahampo.capsule").isEmpty
        if !previewBesideInstalledApp {
            shortcut = Shortcut({ [weak self] in self?.summon() },
                                microphoneAction: { [weak self] in self?.toggleCapsule() })
        }

        let menu = NSMenu()
        add(menu, "Show Capsule", #selector(showCapsule), "")
        add(menu, "Settings…", #selector(showSettings), ",")
        menu.addItem(.separator())
        add(menu, "Quit Amapoani", #selector(quit), "q")
        let main = NSMenu()
        let app = NSMenuItem(title: "Amapoani", action: nil, keyEquivalent: "")
        app.submenu = menu
        main.addItem(app)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = BrandIcon.menuImage
        status.menu = menu.copy() as? NSMenu
        statusItem = status
        capsule.onAppearanceChanged = { [weak self] in self?.refreshBrandIcon() }
        applyPreferences()
        launched = true
        reveal(place: true)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showCapsule()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.reset()
        track?.stop()
        unload()
    }

    private func add(_ menu: NSMenu, _ label: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: label, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func showSettings() {
        let settings = self.settings ?? Settings(models: models)
        self.settings = settings
        settings.changed = { [weak self] in
            guard let self else { return }
            applyPreferences()
            self.settings?.window?.appearance = panel.appearance
        }
        settings.positionChanged = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: "capsuleOrigin")
            chooseCapsuleAnchor(restore: false)
            render()
        }
        settings.modelsChanged = { [weak self] model in
            guard let self else { return }
            if let model {
                if model == .reading && session.state.reading {
                    refreshReadingWorker = true
                    return
                }
                if model != .reading && (session.state.dictating || dictationRequest != nil || checking) { return }
                workers.removeValue(forKey: model == .reading ? .reading : .dictation)?.shutdown()
            } else {
                unload()
            }
        }
        settings.cancelMicrophone = { [weak self] in
            guard let self, checking else { return }
            micCheckID = UUID()
            capture.reset()
            checking = false
            scheduleIdle()
        }
        settings.allowModelChanges = { [weak self] in
            guard let self else { return false }
            return session.state.phase == "standard" && !checking && dictationRequest == nil && readRequest == nil
        }
        settings.previewVoice = { [weak self] voice in self?.previewReadingVoice(voice) }
        settings.stopVoicePreview = { [weak self] in
            if self?.source == .preview { self?.cancel() }
        }
        settings.microphone = { [weak self] completion in self?.micCheck(completion) }
        settings.window?.appearance = panel.appearance
        settings.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func applyPreferences() {
        let prefs = UserDefaults.standard
        session.apply("policy", [
            "idle_ms": prefs.integer(forKey: Preference.idle) * 60_000,
            "keep_loaded": prefs.bool(forKey: Preference.keep), "now": uptimeMS()
        ])
        let appearance = prefs.integer(forKey: Preference.appearance)
        panel.appearance = appearance == 1 ? NSAppearance(named: .aqua) :
            appearance == 2 ? NSAppearance(named: .darkAqua) : nil
        refreshBrandIcon()
        let microphoneEnabled = prefs.bool(forKey: Preference.microphoneShortcut)
        let microphoneKeyAvailable = shortcut?.bindMicrophoneKey(microphoneEnabled)
        let summonOption = prefs.integer(forKey: "shortcut") == 1 ? 1 : 0
        let summonAvailable = shortcut?.bind(summonOption)
        if let item = statusItem?.menu?.items.first {
            if summonAvailable != false {
                item.keyEquivalent = " "
                item.keyEquivalentModifierMask = [summonOption == 1 ? .control : .option, .shift]
            } else {
                item.keyEquivalent = microphoneEnabled && microphoneKeyAvailable == true ? String(UnicodeScalar(NSF13FunctionKey)!) : ""
                item.keyEquivalentModifierMask = []
            }
            let shortcuts = [microphoneEnabled && microphoneKeyAvailable == true ? "Microphone key (F13)" : nil,
                             summonAvailable != false ? CapsuleShortcuts.summonOptions[summonOption] : nil].compactMap { $0 }
            item.toolTip = shortcuts.isEmpty ? "Show Capsule" : "Show Capsule: " + shortcuts.joined(separator: " or ")
            statusItem?.button?.toolTip = "Amapoani · " + (item.toolTip ?? "Show Capsule")
        }
        if summonAvailable == false {
            notice = "Shortcut unavailable. Choose another in Settings."
        } else if microphoneKeyAvailable == false {
            notice = "The microphone shortcut couldn’t be registered. Use the other shortcut."
        }
        render()
        scheduleIdle()
    }

    private func refreshBrandIcon() {
        BrandIcon.apply(appearance: capsule.effectiveAppearance)
    }

    @objc private func summon() {
        if session.state.visible && panel.isKeyWindow && session.state.phase == "standard" {
            dismiss()
            return
        }
        showCapsule()
    }

    private func toggleCapsule() {
        if !session.state.visible {
            showCapsule()
        } else if !session.state.reading && !session.state.dictating {
            dismiss()
        }
    }

    @objc func showCapsule() {
        guard launched else { return }
        reveal(place: !session.state.visible)
        guard session.state.phase == "standard", session.state.recovery == nil else {
            focusCapsule()
            return
        }
        let invocation = UUID()
        invocationID = invocation
        invocationTarget = nil
        // Resolve the external first responder before AppKit transfers keyboard focus.
        desktop.captureInvocation { [weak self] target in
            guard let self, invocationID == invocation, session.state.visible, dictationRequest == nil else { return }
            invocationTarget = target
            focusCapsule()
        }
    }

    private func focusCapsule() {
        panel.makeKey()
        panel.makeFirstResponder(capsule)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        invocationID = nil
        invocationTarget = nil
    }

    private func handle(_ command: CapsuleCommand) {
        guard session.state.visible else { return }
        if session.state.phase == "standard", session.state.recovery != nil {
            switch command {
            case .read: readTranscript()
            case .dictate: dictate()
            case .editDraft: editTranscript()
            case .copyDraft: if readyTranscript != nil { copyCurrentText() }
            case .clearDraft: break
            }
            return
        }
        switch command {
        case .copyDraft:
            if !session.state.dictating, !session.state.draft.isEmpty { copyCurrentText() }
        case .clearDraft:
            if session.state.phase == "standard" || (session.state.reading && session.state.readingView == "draft") {
                capsule.clearDraft()
            }
        case .read:
            if session.state.phase == "standard", !checking, dictationRequest == nil { read() }
        case .dictate:
            if session.state.phase == "standard", readRequest == nil { dictate() }
        case .editDraft:
            if session.state.reading {
                session.apply("reading_view", ["view": "draft"])
            } else if session.state.phase == "standard", session.state.recovery == nil {
                session.apply("expand", ["expanded": true])
            } else {
                return
            }
            render()
            capsule.focusDraft()
        }
    }

    private func reveal(place: Bool, preload: Bool = true) {
        session.apply("show", ["now": uptimeMS()])
        idle?.invalidate()
        idle = nil
        if place { chooseCapsuleAnchor(restore: true) }
        render()
        panel.orderFrontRegardless()
        if preload {
            hideAfterPreview = false
            _ = worker(.reading)
            _ = worker(.dictation)
        }
    }

    private func chooseCapsuleAnchor(restore: Bool) {
        let prefs = UserDefaults.standard
        let saved = restore ? prefs.dictionary(forKey: "capsuleOrigin") : nil
        let stored: CGPoint?
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double, x.isFinite, y.isFinite {
            stored = CGPoint(x: x, y: y)
        } else {
            stored = nil
        }
        let current = panel.isVisible ? panel.screen : nil
        let screen = stored.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
            ?? current ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let position = CapsulePosition(rawValue: prefs.integer(forKey: Preference.capsulePosition)) ?? .bottomCenter
        let width = min(CGFloat(560), visible.width - 40)
        capsuleAnchor = stored.flatMap { screen?.frame.contains($0) == true ? $0 : nil }
            ?? position.anchor(in: visible, width: width)
        appliedFrame = panel.capsuleFrame
    }

    private func dismiss() {
        guard deliveryRequest?.cancel() != false else { return }
        readRequest = nil
        dictationRequest = nil
        invocationID = nil
        invocationTarget = nil
        destination = .draft
        if session.state.phase != "standard" { cancel() }
        session.apply("hide", ["now": uptimeMS()])
        panel.orderOut(nil)
        notice = ""
        scheduleIdle()
    }

    private func scheduleIdle() {
        idle?.invalidate()
        idle = nil
        guard !checking, let hiddenSince = session.state.hiddenSince,
              !UserDefaults.standard.bool(forKey: Preference.keep) else { return }
        let limit = Double(UserDefaults.standard.integer(forKey: Preference.idle)) * 60
        let elapsed = Double(uptimeMS() - hiddenSince) / 1000
        idle = Timer.scheduledTimer(withTimeInterval: max(0, limit - elapsed) + 0.005, repeats: false) { [weak self] _ in
            guard let self else { return }
            if session.apply("tick", ["now": uptimeMS()]).offload {
                unload()
                destination = .draft
                reviewTarget = .draft
                editingTranscript = false
                capsule.discardDraftHistory()
                render()
            }
        }
    }

    private func worker(_ model: Model, voice: ReadingVoice? = nil, language: SpeechLanguage? = nil) -> Worker? {
        if model == .reading && voice == nil && session.state.reading { return workers[model] }
        if model == .dictation && (session.state.dictating || dictationRequest != nil || checking),
           let active = workers[model] { return active }
        var engine = model
        var candidates: [URL]
        var voiceFile: URL?
        if model == .reading {
            let preferred: SpeechLanguage = SpeechLanguage.preference == .spanish ? .spanish : .english
            guard let readingVoice = voice ?? voices.selected(for: preferred) else { return nil }
            voiceFile = voices.standalone(readingVoice)
            if refreshReadingWorker {
                workers.removeValue(forKey: .reading)?.shutdown()
                refreshReadingWorker = false
            }
            candidates = models.candidates(for: .reading, separateVoice: voiceFile != nil)
        } else {
            let requested = language ?? (session.state.dictating ? dictationLanguage.mode : SpeechLanguage.preference)
            candidates = models.candidates(for: .multilingualDictation)
            if candidates.isEmpty {
                guard requested != .spanish else { return nil }
                candidates = models.candidates(for: .dictation)
            } else {
                engine = .multilingualDictation
            }
        }
        if let active = workers[model], active.model == engine, active.voiceFile == voiceFile { return active }
        workers.removeValue(forKey: model)?.shutdown()
        guard !candidates.isEmpty else { return nil }
        let worker = Worker(model: engine, candidates: candidates, models: models, voiceFile: voiceFile)
        workers[model] = worker
        return worker
    }

    private func unload() {
        workers.values.forEach { $0.shutdown() }
        workers.removeAll()
    }

    private func render(undoableDraft: Bool = false) {
        capsule.update(session.state, notice: notice, source: source?.rawValue ?? "",
                       destination: (session.state.dictating ? destination : reviewTarget).label,
                       undoableDraft: undoableDraft, language: .preference,
                       editingTranscript: editingTranscript, insertingTranscript: deliveryRequest != nil)
        capsule.dictationProgress(Double(capture.frameCount) / 16_000)
        sizeCapsule()
        showProgress()
    }

    private func sizeCapsule() {
        rememberDraggedPosition()
        guard let anchor = capsuleAnchor,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? panel.screen ?? NSScreen.main
        else { return }
        let usable = screen.visibleFrame.insetBy(dx: CapsulePanel.shadowInset, dy: CapsulePanel.shadowInset)
        let preferred = CapsuleExpansion(rawValue: UserDefaults.standard.integer(forKey: Preference.capsuleExpansion)) ?? .upward
        let layout = CapsulePlacement(anchor: anchor, width: min(560, screen.visibleFrame.width - 40),
                                      height: capsule.height, expandedHeight: capsule.preferredExpandedHeight,
                                      inside: usable, preferred: preferred)
        capsuleAnchor = layout.anchor
        capsule.expansion = layout.expansion
        appliedRowOffset = capsule.rowOffset
        appliedFrame = layout.frame
        if panel.capsuleFrame != layout.frame { panel.setCapsuleFrame(layout.frame, display: true) }
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, rememberDraggedPosition() else { return }
        settleDraggedCapsule()
    }

    private func settleDraggedCapsule() {
        dragSettlement?.invalidate()
        dragSettlement = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            guard let self else { return }
            dragSettlement = nil
            guard panel.isVisible else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 { sizeCapsule() }
            else { settleDraggedCapsule() }
        }
    }

    @discardableResult
    private func rememberDraggedPosition() -> Bool {
        guard panel.isVisible, let appliedFrame, panel.capsuleFrame.origin != appliedFrame.origin else { return false }
        let frame = panel.capsuleFrame
        let anchor = CGPoint(x: frame.minX, y: frame.minY + appliedRowOffset)
        capsuleAnchor = anchor
        self.appliedFrame = frame
        UserDefaults.standard.set(["x": Double(anchor.x), "y": Double(anchor.y)], forKey: "capsuleOrigin")
        return true
    }

    private func act(_ action: String) {
        switch action {
        case "language":
            guard session.state.phase == "standard", dictationRequest == nil, readRequest == nil, !checking else { return }
            UserDefaults.standard.set(Int(SpeechLanguage.preference.next.rawValue), forKey: Preference.language)
            settings?.refreshLanguage()
            render()
        case "primary":
            if session.state.reading { togglePlayback() }
            else if session.state.dictating { toggleDictation() }
            else { dictate() }
        case "secondary":
            if session.state.reading { cancel() }
            else if session.state.dictating { finishDictation() }
            else { read() }
        case "expand":
            notice = ""
            session.apply("expand", ["expanded": !session.state.expanded])
            render()
            capsule.focusDraft()
        case "insert": insertTranscript()
        case "discardTranscript": discardTranscript()
        case "recordAgain": dictate()
        case "editTranscript": editTranscript()
        case "readTranscript": readTranscript()
        case "copy": copyCurrentText()
        case "follow", "draft", "compact":
            session.apply("reading_view", ["view": action])
            render()
            if action == "draft" { capsule.focusDraft() }
        default: return
        }
    }

    private func copyCurrentText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let text = session.state.reading ? session.state.draft : session.state.recovery ?? session.state.draft
        pasteboard.setString(text, forType: .string)
    }

    private func inform(_ message: String) {
        notice = message
        render()
        NSAccessibility.post(element: capsule, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            notice = ""
            capsule.updateNotice("")
            sizeCapsule()
        }
    }

    private func read() {
        guard readRequest == nil else { return }
        dictationRequest = nil
        let request = Desktop.Request()
        let draft = session.state.draft
        let language = SpeechLanguage.preference
        readRequest = request
        desktop.selection(request: request) { [weak self] selection in
            guard let self, readRequest === request else { return }
            readRequest = nil
            guard session.state.visible, session.state.phase == "standard" else { return }
            if case let .text(text) = selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startRead(text, from: .selection, language: language)
            } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startRead(draft, from: .draft, language: language)
            } else if case .permissionRequired = selection {
                inform("Allow Amapoani in Privacy & Security to read selected text.")
            } else {
                inform("Select text or type a draft.")
            }
        }
    }

    @objc(readSelectedText:userData:error:)
    private func readSelectedText(_ pasteboard: NSPasteboard, userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "Select text before using Read Selection in Amapoani."
            return
        }
        guard !session.state.dictating, dictationRequest == nil, !checking else {
            error?.pointee = "Finish recording before reading a selection."
            return
        }
        let language = SpeechLanguage.preference.forReading(text)
        guard let selected = voices.selected(for: language) else {
            error?.pointee = "Add a \(language == .spanish ? "Spanish" : "English") reading voice in Amapoani Settings." as NSString
            return
        }
        guard !models.candidates(for: .reading, separateVoice: voices.standalone(selected) != nil).isEmpty else {
            error?.pointee = missingReadingAssets(for: selected) as NSString
            return
        }
        readRequest = nil
        if session.state.reading { cancel() }
        reveal(place: !session.state.visible)
        startRead(text, from: .selection, voice: selected)
    }

    private func previewReadingVoice(_ voice: ReadingVoice) -> String? {
        guard !checking, dictationRequest == nil, readRequest == nil,
              session.state.phase == "standard" || (source == .preview && session.state.reading) else {
            return "Finish your current speech task before previewing a voice."
        }
        if session.state.reading { cancel() }
        if !session.state.visible {
            hideAfterPreview = true
            reveal(place: true, preload: false)
        }
        let sample = voice.sample
        if voices.enabled.contains(voice), !models.candidates(for: .reading, separateVoice: voices.standalone(voice) != nil).isEmpty {
            startRead(sample, from: .preview, voice: voice)
            return nil
        }
        do {
            let data = try Self.sampleAudio(voice)
            guard let task = beginReading(sample, from: .preview, language: voice.language), let track else { return nil }
            let range = NSRange(sample.startIndex..., in: sample)
            phrases = [ReadingPhrase(text: sample, range: range, endsParagraph: false)]
            guard try track.append(data: data, range: range, cap: readingCap) else {
                throw ModelError("This voice sample could not be decoded.")
            }
            track.finishedGenerating = true
            session.apply("play", ["task": task])
            try track.play()
            render()
            return "Reference sample · Natural pauses · 1×"
        } catch {
            if source == .preview { cancel() }
            restoreAfterPreview()
            return error.localizedDescription
        }
    }

    private static func sampleAudio(_ voice: ReadingVoice) throws -> Data {
        guard let url = Bundle.main.url(forResource: voice.filename, withExtension: "wav", subdirectory: "VoiceSamples") else {
            throw ModelError("This voice sample is missing from the app.")
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length <= 24000 * 30, file.processingFormat.sampleRate == 24000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)) else {
            throw ModelError("This voice sample could not be decoded.")
        }
        try file.read(into: buffer)
        var rate = UInt32(24000).littleEndian
        var data = Data(bytes: &rate, count: 4)
        data.append(Data(bytes: buffer.floatChannelData![0], count: Int(buffer.frameLength) * 4))
        return data
    }

    private func startRead(_ text: String, from source: ReadingSource, voice: ReadingVoice? = nil,
                           language: SpeechLanguage = .preference) {
        let spokenLanguage = voice?.language ?? language.forReading(text)
        guard let chosen = voice ?? voices.selected(for: spokenLanguage) else {
            inform(spokenLanguage == .spanish ? "Add a Spanish reading voice in Settings." :
                   "Add an English reading voice in Settings.")
            return
        }
        guard let worker = worker(.reading, voice: chosen) else {
            inform(missingReadingAssets(for: chosen))
            return
        }
        guard let task = beginReading(text, from: source, language: spokenLanguage) else { return }
        generate(0, task: task, worker: worker, options: ReadingOptions(voice: chosen))
    }

    private func missingReadingAssets(for voice: ReadingVoice) -> String {
        if !models.candidates(for: .reading, separateVoice: true).isEmpty {
            return "Download \(voice.label) in Settings → Speech."
        }
        return "Download Kokoro in Amapoani Settings."
    }

    private func beginReading(_ text: String, from source: ReadingSource, language: SpeechLanguage) -> UInt64? {
        notice = ""
        let state = session.apply("read", ["source": text])
        guard state.snapshot != nil else { render(); return nil }
        self.source = source
        let playback = Track()
        track = playback
        playback.onEnd = { [weak self] in self?.finishReading(state.task) }
        readingCap = Double(UserDefaults.standard.integer(forKey: Preference.reading) * 60)
        pendingSeek = nil
        phrases = ReadingPhrase.split(text, language: language)
        render()
        pulse()
        return state.task
    }

    private func generate(_ index: Int, task: UInt64, worker: Worker, options: ReadingOptions) {
        guard session.state.task == task, let track else { return }
        guard index < phrases.count, track.end + 0.001 < readingCap else {
            track.finishedGenerating = true
            if pendingSeek != nil {
                pendingSeek = nil
                notice = "That passage is beyond the generated audio."
                if session.state.phase == "playing" { try? track.play() }
                render()
            }
            if track.chunks.isEmpty || (track.position >= track.end && session.state.phase == "playing") {
                finishReading(task)
            }
            return
        }
        let phrase = phrases[index]
        worker.speak(phrase, with: options) { [weak self, weak track] reply in
            guard let self, let track, self.session.state.task == task else { return }
            do {
                let prior = track.end
                if try track.append(data: reply.get(), range: phrase.range, cap: readingCap) {
                    if session.state.phase == "loading" {
                        session.apply("play", ["task": task])
                        try track.play()
                        render()
                    }
                    if pendingSeek == index {
                        pendingSeek = nil
                        notice = ""
                        try track.seek(prior, resume: session.state.phase == "playing")
                        render()
                    }
                }
                generate(index + 1, task: task, worker: worker, options: options)
            } catch {
                workers.removeValue(forKey: .reading)?.shutdown()
                cancel()
                notice = error.localizedDescription
                render()
            }
        }
    }

    private func move(to time: Double) {
        guard let track else { return }
        pendingSeek = nil
        notice = ""
        try? track.seek(time, resume: session.state.phase == "playing")
        render()
    }

    private func seekPhrase(at offset: Int) {
        guard let track, session.state.readingView == "follow",
              let index = phrases.firstIndex(where: { NSLocationInRange(offset, $0.range) }) else { return }
        if let chunk = track.chunks.first(where: { $0.range == phrases[index].range }) {
            move(to: chunk.start)
        } else if !track.finishedGenerating {
            pendingSeek = index
            track.pause()
            notice = "Preparing this passage"
            render()
        }
    }

    private func togglePlayback() {
        guard let track else { return }
        let state = session.apply("pause", ["task": session.state.task])
        if state.phase == "playback_paused" { track.pause() }
        else if state.phase == "playing" && pendingSeek == nil { try? track.play() }
        render()
    }

    private func finishReading(_ task: UInt64) {
        guard session.state.task == task else { return }
        session.apply("read_done", ["task": task])
        clock?.invalidate()
        track?.stop()
        track = nil
        source = nil
        notice = ""
        phrases.removeAll()
        pendingSeek = nil
        render()
        restoreAfterPreview()
    }

    private func restoreAfterPreview() {
        guard hideAfterPreview else { return }
        hideAfterPreview = false
        session.apply("hide", ["now": uptimeMS()])
        panel.orderOut(nil)
        scheduleIdle()
    }

    private func showProgress() {
        guard let track else { return }
        let position = track.position
        let highlight = track.chunks.last(where: { $0.start <= position })?.range
        capsule.progress(current: position, ready: track.end, highlight: highlight)
    }

    private func withMicrophone(_ work: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: work(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { work(allowed) } }
        default: work(false)
        }
    }

    private func dictate() {
        guard session.state.phase == "standard", !checking, dictationRequest == nil, deliveryRequest == nil else { return }
        readRequest = nil
        let language = SpeechLanguage.preference
        guard worker(.dictation, language: language) != nil else {
            inform(language == .spanish ? "Download bilingual Whisper in Amapoani Settings." :
                   "Download Whisper in Amapoani Settings.")
            return
        }
        dictationLanguage = DictationLanguage(mode: language)
        let request = UUID()
        dictationRequest = request
        destination = .draft
        if session.state.recovery != nil {
            destination = reviewTarget
            requestMicrophone(for: request)
            return
        }
        if capsule.isEditingDraft {
            requestMicrophone(for: request)
            return
        }
        if panel.isKeyWindow, let invocationTarget {
            destination = invocationTarget
            requestMicrophone(for: request)
            return
        }
        desktop.captureInvocation { [weak self] captured in
            guard let self, dictationRequest == request, session.state.visible else { return }
            destination = captured
            requestMicrophone(for: request)
        }
    }

    private func requestMicrophone(for request: UUID) {
        withMicrophone { [weak self] allowed in
            guard let self, dictationRequest == request else { return }
            dictationRequest = nil
            guard session.state.visible, session.state.phase == "standard" else { return }
            if !allowed { notice = "Allow microphone access in System Settings."; render(); return }
            capture.reset()
            capture.maximumFrames = UserDefaults.standard.integer(forKey: Preference.dictation) * 60 * 16000
            notice = ""
            dictationPreview = DictationPreview()
            previewBusy = false
            do {
                try capture.resume()
                editingTranscript = false
                session.apply("dictate", ["external": true])
                render()
                focusCapsule()
                pulse()
            } catch { notice = error.localizedDescription; render() }
        }
    }

    private func toggleDictation() {
        let recording = session.state.phase == "recording"
        if !recording && capture.frameCount >= capture.maximumFrames { return }
        do {
            if recording { capture.pause() } else { try capture.resume() }
            session.apply("pause", ["task": session.state.task])
            if recording { preview(pausing: true) }
            else { pulse() }
            render()
        } catch { notice = error.localizedDescription; render() }
    }

    private func finishDictation() {
        guard session.state.phase != "finishing" else { return }
        guard let worker = worker(.dictation) else {
            inform("Whisper is unavailable. Your recording is still here.")
            return
        }
        let task = session.state.task
        session.apply("finish", ["task": task])
        capture.pause()
        let audio = capture.data()
        clock?.invalidate()
        render()
        worker.transcribe(audio, language: dictationLanguage.decoder) { [weak self] response in
            guard let self, self.session.state.task == task else { return }
            do {
                let text = try response.get().text.trimmingCharacters(in: .whitespacesAndNewlines)
                reviewDictation(task, text: text)
            } catch {
                workers.removeValue(forKey: .dictation)?.shutdown()
                session.apply("recognition_failed", ["task": task])
                inform((error as? ModelError)?.errorDescription ?? "Couldn’t finish dictation. Press Finish to try again.")
            }
        }
    }

    private func reviewDictation(_ task: UInt64, text: String) {
        if !text.isEmpty {
            if session.state.recovery != nil { session.apply("clear_recovery") }
            if case .field = destination { reviewTarget = destination }
            else { reviewTarget = .draft }
        }
        destination = .draft
        session.apply("transcript", ["task": task, "text": text])
        capture.reset()
        dictationPreview = DictationPreview()
        if text.isEmpty { inform("No speech detected") }
        else { render() }
    }

    private func confirmDictation() -> Bool {
        if session.state.dictating {
            finishDictation()
        } else if session.state.phase == "standard", session.state.recovery != nil {
            insertTranscript()
        } else {
            return false
        }
        return true
    }

    private func escape() {
        if session.state.phase != "standard" { cancel() }
        else if session.state.recovery != nil { discardTranscript() }
        else { dismiss() }
    }

    private var readyTranscript: String? {
        guard session.state.phase == "standard", dictationRequest == nil, deliveryRequest == nil else { return nil }
        return session.state.recovery
    }

    private func discardTranscript() {
        guard readyTranscript != nil else { return }
        editingTranscript = false
        reviewTarget = .draft
        session.apply("clear_recovery")
        notice = ""
        render()
        focusCapsule()
    }

    private func editTranscript() {
        guard readyTranscript != nil else { return }
        editingTranscript = true
        render()
        capsule.focusTranscript()
    }

    private func readTranscript() {
        guard let text = readyTranscript, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editingTranscript = false
        focusCapsule()
        startRead(text, from: .transcript)
    }

    private func insertTranscript() {
        guard let transcript = readyTranscript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notice = ""
        editingTranscript = false
        guard case let .field(field) = reviewTarget else {
            session.apply("insert_recovery")
            render(undoableDraft: true)
            capsule.focusDraft()
            return
        }
        focusCapsule()
        let request = Desktop.Request()
        deliveryRequest = request
        render()
        desktop.deliver(transcript, to: field, request: request) { [weak self] delivery in
            guard let self, deliveryRequest === request else { return }
            deliveryRequest = nil
            reviewTarget = .draft
            switch delivery {
            case .confirmed(let updated):
                invocationTarget = updated.map(DictationTarget.field)
                session.apply("clear_recovery")
                inform("Inserted in original field")
            case .alreadyPresent:
                session.apply("clear_recovery")
                inform("The field already contains this text")
            case .unavailable:
                inform("Original field changed. You can insert into Draft.")
            case .uncertain:
                inform("Couldn’t confirm insertion. The transcript is still here.")
            }
        }
    }

    private func pulse() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            showProgress()
            if session.state.phase == "recording" {
                capsule.dictationProgress(Double(capture.frameCount) / 16_000)
                if capture.frameCount >= capture.maximumFrames {
                    capture.pause()
                    session.apply("pause", ["task": session.state.task])
                    notice = "Time limit reached. Finish to keep the transcript."
                    render()
                } else { preview() }
            } else if session.state.phase == "dictation_paused" { preview(pausing: true) }
        }
    }

    private func preview(pausing: Bool = false) {
        guard !previewBusy, let worker = worker(.dictation),
              let frames = dictationPreview.request(available: capture.frameCount, pause: pausing) else { return }
        previewBusy = true
        let task = session.state.task
        worker.transcribe(capture.data(in: frames), language: dictationLanguage.decoder) { [weak self] reply in
            guard let self, session.state.task == task else { return }
            previewBusy = false
            guard session.state.phase == "recording" || session.state.phase == "dictation_paused" else { return }
            let result = try? reply.get()
            if let result { dictationLanguage.observe(result, frames: frames.count) }
            if let text = dictationPreview.receive(result?.text, for: frames) {
                session.apply("preview", ["task": task, "text": text])
                render()
            }
        }
    }

    private func cancel() {
        guard deliveryRequest?.cancel() != false else { return }
        let recording = session.state.dictating
        deliveryRequest = nil
        session.apply("cancel")
        clock?.invalidate()
        clock = nil
        track?.stop()
        track = nil
        phrases.removeAll()
        source = nil
        capture.reset()
        dictationPreview = DictationPreview()
        pendingSeek = nil
        if recording { workers.removeValue(forKey: .dictation)?.shutdown() }
        notice = ""
        render()
        restoreAfterPreview()
    }

    private func micCheck(_ completion: @escaping (String) -> Void) {
        guard session.state.phase == "standard", !checking, dictationRequest == nil else {
            completion("A speech task is already active.")
            return
        }
        let language = SpeechLanguage.preference
        guard let worker = worker(.dictation, language: language) else {
            completion(language == .spanish ? "Download bilingual Whisper first." : "Download Whisper first.")
            return
        }
        checking = true
        scheduleIdle()
        let id = UUID()
        micCheckID = id
        withMicrophone { [weak self] allowed in
            guard let self, micCheckID == id else { return }
            if !allowed { checking = false; scheduleIdle(); completion("Microphone permission is unavailable."); return }
            capture.reset()
            capture.maximumFrames = 80_000
            do { try capture.resume() }
            catch { checking = false; scheduleIdle(); completion(error.localizedDescription); return }
            completion("Listening for five seconds…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, micCheckID == id else { return }
                capture.pause()
                let audio = capture.data()
                capture.reset()
                worker.transcribe(audio, language: language) { [weak self] result in
                    guard let self, micCheckID == id else { return }
                    checking = false
                    scheduleIdle()
                    switch result {
                    case .success(let transcript):
                        let words = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        completion(words.isEmpty ? "No speech detected." : words)
                    case .failure(let error): completion(error.localizedDescription)
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
let handoff = LaunchHandoff()
switch handoff.claim() {
case .primary:
    break
case .forwarded:
    exit(EXIT_SUCCESS)
case .unavailable:
    fputs("Amapoani could not connect to its running session.\n", stderr)
    exit(EXIT_FAILURE)
}
let delegate = App()
app.delegate = delegate
handoff.showCapsule = { [weak delegate] in delegate?.showCapsule() }
withExtendedLifetime(handoff) { app.run() }
