import AppKit

private final class SettingsContent: NSView {
    override var isFlipped: Bool { true }
}

private enum SettingsPage: String, CaseIterable {
    case capsule = "Capsule", shortcuts = "Shortcuts", speech = "Speech", models = "Models", access = "Access"
}

final class Settings: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var changed: (() -> Void)?
    var positionChanged: (() -> Void)?
    var modelsChanged: ((Model?) -> Void)?
    var cancelMicrophone: (() -> Void)?
    var allowModelChanges: (() -> Bool)?
    var previewVoice: ((ReadingVoice) -> String?)?
    var stopVoicePreview: (() -> Void)?
    var microphone: ((@escaping (String) -> Void) -> Void)?
    private let models: Models
    private let library: VoiceLibrary
    private var languagePicker: NSPopUpButton?
    private let voices = NSPopUpButton()
    private let spanishVoices = NSPopUpButton()
    private let catalog = NSPopUpButton()
    private let manageVoice = NSButton()
    private let upgrade = NSButton()
    private let speedValue = NSTextField(labelWithString: "")
    private var addingVoice = false
    private var body = NSStackView()
    private let pages = NSTabView()
    private let shortcutModifier = NSPopUpButton()
    private var shortcutKeys: [CapsuleCommand: NSPopUpButton] = [:]
    private let setup = NSButton(title: "Download Missing Models", target: nil, action: nil)
    private let modelDetail = NSTextField(wrappingLabelWithString: "")
    private let voiceDetail = NSTextField(wrappingLabelWithString: "")
    private let microphoneDetail = NSTextField(wrappingLabelWithString: "")
    private let path = NSTextField(wrappingLabelWithString: "")
    private let accessStatus = NSTextField(labelWithString: "")
    private let accessButton = NSButton(title: "Allow Access…", target: nil, action: nil)
    private let copyAccess = NSButton(title: "Set Up Clipboard Access…", target: nil, action: nil)
    private var modelLabels: [Model: NSTextField] = [:]
    private var modelButtons: [Model: NSButton] = [:]
    private var resolvedModels: [Model: URL] = [:]
    private var verification = UUID()
    private var downloads = Set<Model>()
    private var installingRuntime = false
    private let prefs = UserDefaults.standard
    private var accessCheck: Timer?

    init(models: Models) {
        self.models = models
        library = VoiceLibrary(models: models)
        super.init(window: NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 546),
                                   styleMask: [.titled, .closable, .miniaturizable],
                                   backing: .buffered, defer: false))
        window?.title = "Amapoani Settings"
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            window?.subtitle = "Version " + version + " (" + build + ")"
        }
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        let content = NSView()
        let navigation = NSSegmentedControl(labels: SettingsPage.allCases.map(\.rawValue), trackingMode: .selectOne,
                                            target: self, action: #selector(changePage))
        navigation.segmentStyle = .rounded
        navigation.selectedSegment = 0
        navigation.setAccessibilityLabel("Settings sections")
        let divider = NSBox()
        divider.boxType = .separator
        pages.tabViewType = .noTabsNoBorder
        for view in [navigation, divider, pages] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        window?.contentView = content
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            navigation.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            divider.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 13),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pages.topAnchor.constraint(equalTo: divider.bottomAnchor),
            pages.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pages.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        beginPage(.capsule)
        section("Appearance")
        let appearance = popup(["System", "Light", "Dark"], key: Preference.appearance, label: "Appearance")
        let position = popup(CapsulePosition.allCases.map(\.label), key: Preference.capsulePosition,
                             label: "Starting position")
        let expansion = popup(["Upward", "Downward"], key: Preference.capsuleExpansion,
                              label: "Preferred expansion")
        position.toolTip = "Choose where the capsule starts. Drag it to move it anywhere."
        expansion.toolTip = "The editor opens in the other direction when there is more room."
        row("Theme", appearance)
        let icon = popup(BrandIcon.labels, key: Preference.iconStyle, label: "App icon")
        icon.toolTip = "Automatic uses Azul in light appearance and Rosa in dark appearance."
        row("App icon", icon)
        section("Placement")
        row("Starting position", position)
        row("Preferred expansion", expansion)
        section("Memory")
        let keep = NSButton(checkboxWithTitle: "Keep models loaded when the capsule closes",
                            target: self, action: #selector(keepChanged))
        keep.state = prefs.bool(forKey: Preference.keep) ? .on : .off
        body.addArrangedSubview(keep)
        row("Unload after", duration(Preference.idle))

        beginPage(.shortcuts)
        section("Show Capsule")
        row("Global shortcut", popup(CapsuleShortcuts.summonOptions, key: "shortcut", label: "Global shortcut"))
        let microphoneKey = NSButton(checkboxWithTitle: "Use the microphone key (F13)",
                                     target: self, action: #selector(microphoneKeyChanged))
        microphoneKey.state = prefs.bool(forKey: Preference.microphoneShortcut) ? .on : .off
        microphoneKey.toolTip = "Requires mapping your keyboard’s Dictation key to F13. The shortcut above also works."
        body.addArrangedSubview(microphoneKey)
        section("While the capsule has focus")
        shortcutModifier.addItems(withTitles: CapsuleShortcuts.Modifier.allCases.map(\.title))
        shortcutModifier.setAccessibilityLabel("Capsule modifier")
        shortcutModifier.target = self
        shortcutModifier.action = #selector(shortcutModifierChanged)
        row("Modifier for all actions", shortcutModifier)
        for command in CapsuleCommand.allCases {
            let picker = NSPopUpButton()
            picker.autoenablesItems = false
            picker.addItems(withTitles: CapsuleShortcuts.keys.map { $0.uppercased() })
            picker.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            picker.setAccessibilityLabel(command.label + " shortcut")
            picker.target = self
            picker.action = #selector(shortcutKeyChanged)
            shortcutKeys[command] = picker
            row(command.label, picker)
        }
        body.addArrangedSubview(button("Restore Defaults", #selector(restoreShortcutDefaults)))
        refreshShortcuts()

        beginPage(.speech)
        section("Language")
        let language = popup(SpeechLanguage.allCases.map(\.label), key: Preference.language, label: "Speech language")
        language.toolTip = "Language for reading and dictation. Automatic dictation uses bilingual Whisper."
        languagePicker = language
        row("Speech language", language)

        section("Reading")
        buildReadingControls()
        section("Session limits")
        row("Maximum reading", duration(Preference.reading))
        row("Maximum dictation", duration(Preference.dictation))

        beginPage(.models)
        section("Installed models")
        path.textColor = .secondaryLabelColor
        path.font = .systemFont(ofSize: 12)
        body.addArrangedSubview(path)
        let folders = NSStackView(views: [button("Choose Folder…", #selector(folderClicked)),
                                          button("Add Search Location…", #selector(searchClicked))])
        body.addArrangedSubview(folders)
        for model in Model.allCases {
            let detail = NSTextField(labelWithString: "")
            if model == .dictation {
                detail.setAccessibilityHelp("Legacy fallback for existing English-only installations. The multilingual model also handles English.")
            }
            modelLabels[model] = detail
            let action = button("", #selector(modelClicked))
            action.identifier = NSUserInterfaceItemIdentifier(model.rawValue)
            modelButtons[model] = action
            let group = NSStackView(views: [detail, action])
            group.spacing = 10
            row(model.label, group)
        }
        setup.target = self
        setup.action = #selector(setupClicked)
        body.addArrangedSubview(setup)
        modelDetail.font = .systemFont(ofSize: 11)
        modelDetail.textColor = .secondaryLabelColor
        body.addArrangedSubview(modelDetail)
        upgrade.title = "Download Higher-Quality Kokoro…"
        upgrade.target = self
        upgrade.action = #selector(upgradeReading)
        upgrade.isHidden = true
        body.addArrangedSubview(upgrade)

        beginPage(.access)
        section("Browser access")
        accessButton.target = self
        accessButton.action = #selector(requestAccessibility)
        row("Accessibility", NSStackView(views: [accessStatus, accessButton]))
        if #available(macOS 15.4, *) {
            copyAccess.target = self
            copyAccess.action = #selector(setUpCopyFallback)
            copyAccess.toolTip = "Verify selected text and insert dictation into browser fields."
            row("Clipboard", copyAccess)
        }
        let reveal = button("Show Amapoani in Finder", #selector(revealRunningApp))
        reveal.toolTip = Bundle.main.bundlePath
        body.addArrangedSubview(reveal)

        section("Microphone")
        body.addArrangedSubview(button("Run Microphone Check", #selector(microphoneClicked)))
        microphoneDetail.font = .systemFont(ofSize: 12)
        microphoneDetail.textColor = .secondaryLabelColor
        body.addArrangedSubview(microphoneDetail)
        refresh()
    }

    private func buildReadingControls() {
        for (picker, label) in [(voices, "English voice"), (spanishVoices, "Spanish voice")] {
            picker.setAccessibilityLabel(label)
            picker.target = self
            picker.action = #selector(voiceChanged)
            row(label, picker)
        }
        for voice in ReadingVoice.allCases {
            catalog.addItem(withTitle: voice.label)
            catalog.lastItem?.tag = Int(voice.rawValue)
        }
        catalog.selectItem(withTag: Int(library.selected(for: .english)?.rawValue ?? ReadingVoice.heart.rawValue))
        catalog.setAccessibilityLabel("Browse voices")
        catalog.target = self
        catalog.action = #selector(browseVoiceChanged)
        let audition = button("Preview", #selector(previewVoiceClicked))
        audition.setAccessibilityLabel("Preview voice")
        manageVoice.target = self
        manageVoice.action = #selector(manageVoiceClicked)
        let voiceActions = NSStackView(views: [catalog, audition, manageVoice])
        voiceActions.spacing = 7
        row("Voice library", voiceActions)
        voiceDetail.font = .systemFont(ofSize: 12)
        voiceDetail.textColor = .secondaryLabelColor
        voiceDetail.isHidden = true
        body.addArrangedSubview(voiceDetail)
        row("Pauses", popup(["Natural", "Compressed"], key: Preference.pauses, label: "Reading pauses"))
        let speed = NSSlider(value: Double(ReadingOptions(voice: .heart).speed), minValue: 50, maxValue: 200,
                             target: self, action: #selector(speedChanged))
        speed.setAccessibilityLabel("Reading speed")
        speed.widthAnchor.constraint(equalToConstant: 165).isActive = true
        updateSpeedLabel(speed)
        row("Speed", NSStackView(views: [speed, speedValue]))

    }

    required init?(coder: NSCoder) { nil }

    private func refreshAccess() {
        let access = Desktop.hasAccess
        accessStatus.stringValue = access ? "Allowed for this copy" : "Permission required for this copy"
        accessButton.isHidden = access
        if #available(macOS 15.4, *) {
            let enabled = NSPasteboard.general.accessBehavior == .alwaysAllow
            copyAccess.title = enabled ? "Clipboard access allowed" : "Set Up Clipboard Access…"
            copyAccess.isEnabled = !enabled
        }
        if access {
            accessCheck?.invalidate()
            accessCheck = nil
        }
    }

    func refresh() {
        refreshAccess()
        refreshLanguage()
        refreshVoices()
        path.stringValue = models.root.path
        let separateLanguages = [SpeechLanguage.english, .spanish].filter { hasSelectedSeparateVoice(for: $0) }
        let separate = !separateLanguages.isEmpty
        let candidates = Dictionary(uniqueKeysWithValues: Model.allCases.map {
            ($0, models.candidates(for: $0, separateVoice: $0 == .reading && separate))
        })
        let check = UUID()
        verification = check
        resolvedModels.removeAll()
        let needsRuntime = models.runtime.libraryDirectory == nil
        setup.title = needsRuntime ? "Set Up Speech" : "Download Missing Models"
        setup.isHidden = !needsRuntime && [.reading, .multilingualDictation].allSatisfy { !(candidates[$0] ?? []).isEmpty }
        setup.isEnabled = !installingRuntime && downloads.isEmpty
        for model in Model.allCases {
            let found = candidates[model]?.first
            modelLabels[model]?.stringValue = downloads.contains(model) ? "Downloading…" : found == nil ? "Missing" : "Checking…"
            modelLabels[model]?.toolTip = found?.path
            modelButtons[model]?.title = found == nil ? "Download" : "Manage"
            modelButtons[model]?.isEnabled = found == nil && !downloads.contains(model)
        }
        DispatchQueue.global(qos: .utility).async { [models, weak self] in
            let locations = candidates.compactMapValues { entries in
                entries.first
            }
            let valid = Dictionary(uniqueKeysWithValues: candidates.compactMap { model, entries in
                models.verifiedLocation(model, among: entries, separateVoice: model == .reading && separate).map { (model, $0) }
            })
            let readingStatus = valid[.reading].map { pack in
                let packed = !separate || models.verifiedVoiceTable(in: pack)
                let english = packed || separateLanguages.contains(.english)
                let spanish = (packed || separateLanguages.contains(.spanish)) && models.verifiedSpanishPhonemes(in: pack)
                let precision = models.isFullPrecision(pack) ? "Full precision" : "Compact"
                if english && spanish { return precision }
                if english { return precision + " · English only" }
                if spanish { return precision + " · Spanish only" }
                return "Pronunciation files missing"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, verification == check else { return }
                for model in Model.allCases where !downloads.contains(model) {
                    let location = valid[model] ?? locations[model]
                    resolvedModels[model] = location
                    if model == .reading {
                        upgrade.isHidden = valid[model].map { models.isFullPrecision($0) } ?? true
                    }
                    modelLabels[model]?.stringValue = valid[model] != nil
                        ? (model == .reading ? (readingStatus ?? "Damaged") : "Available")
                        : (location == nil ? "Missing" : "Damaged")
                    modelLabels[model]?.toolTip = location?.path
                    modelButtons[model]?.title = location.map { models.owns(model, at: $0) ? "Delete…" : "Detach…" } ?? "Download"
                    modelButtons[model]?.isEnabled = true
                }
            }
        }
    }

    func show() {
        refresh()
        if let screen = window?.screen ?? NSScreen.main {
            window?.setContentSize(NSSize(width: 560, height: min(546, screen.visibleFrame.height - 40)))
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func report(_ message: String) { modelDetail.stringValue = message }

    func refreshLanguage() {
        languagePicker?.selectItem(at: Int(SpeechLanguage.preference.rawValue))
    }

    private func beginPage(_ page: SettingsPage) {
        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        let scrolling = NSScrollView()
        scrolling.drawsBackground = false
        scrolling.hasVerticalScroller = true
        scrolling.autohidesScrollers = true
        let host = SettingsContent()
        host.addSubview(body)
        scrolling.documentView = host
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: scrolling.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: scrolling.contentView.leadingAnchor),
            host.widthAnchor.constraint(equalTo: scrolling.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: host.topAnchor, constant: 22),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22)
        ])
        let tab = NSTabViewItem(identifier: page.rawValue)
        tab.label = page.rawValue
        tab.view = scrolling
        pages.addTabViewItem(tab)
    }

    @objc private func changePage(_ control: NSSegmentedControl) {
        guard SettingsPage.allCases.indices.contains(control.selectedSegment) else { return }
        window?.makeFirstResponder(control)
        pages.selectTabViewItem(at: control.selectedSegment)
    }

    private func refreshShortcuts() {
        let shortcuts = CapsuleShortcuts()
        shortcutModifier.selectItem(at: shortcuts.modifier.rawValue)
        for (command, picker) in shortcutKeys {
            let reserved = Set(CapsuleCommand.allCases.filter { $0 != command }.map { shortcuts.key(for: $0) })
            for item in picker.itemArray { item.isEnabled = !reserved.contains(item.title.lowercased()) }
            picker.selectItem(withTitle: shortcuts.key(for: command).uppercased())
        }
    }

    @objc private func shortcutModifierChanged(_ picker: NSPopUpButton) {
        guard let modifier = CapsuleShortcuts.Modifier(rawValue: picker.indexOfSelectedItem) else { return }
        CapsuleShortcuts().modifier = modifier
        changed?()
    }

    @objc private func shortcutKeyChanged(_ picker: NSPopUpButton) {
        guard let id = picker.identifier?.rawValue, let command = CapsuleCommand(rawValue: id),
              let key = picker.titleOfSelectedItem?.lowercased() else { return }
        CapsuleShortcuts().setKey(key, for: command)
        refreshShortcuts()
        changed?()
    }

    @objc private func restoreShortcutDefaults() {
        CapsuleShortcuts().reset()
        refreshShortcuts()
        changed?()
    }

    private func section(_ title: String) {
        if let previous = body.arrangedSubviews.last { body.setCustomSpacing(24, after: previous) }
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        body.addArrangedSubview(field)
        body.setCustomSpacing(5, after: field)
    }

    private func row(_ name: String, _ control: NSView) {
        let field = NSTextField(labelWithString: name)
        field.widthAnchor.constraint(equalToConstant: 168).isActive = true
        let row = NSStackView(views: [field, control])
        row.alignment = .centerY
        row.spacing = 12
        body.addArrangedSubview(row)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func popup(_ items: [String], key: String, label: String) -> NSPopUpButton {
        let control = NSPopUpButton()
        control.addItems(withTitles: items)
        control.selectItem(at: prefs.integer(forKey: key))
        control.identifier = NSUserInterfaceItemIdentifier(key)
        control.setAccessibilityLabel(label)
        control.target = self
        control.action = #selector(popupChanged)
        return control
    }

    private func duration(_ key: String) -> NSView {
        let input = NSTextField(string: String(prefs.integer(forKey: key)))
        input.identifier = NSUserInterfaceItemIdentifier(key)
        input.setAccessibilityLabel(key == Preference.idle ? "Idle timeout in minutes" :
                                    key == Preference.reading ? "Maximum reading in minutes" : "Maximum dictation in minutes")
        input.widthAnchor.constraint(equalToConstant: 56).isActive = true
        input.target = self
        input.action = #selector(durationChanged)
        input.refusesFirstResponder = false
        input.delegate = self
        return NSStackView(views: [input, NSTextField(labelWithString: "minutes")])
    }

    func controlTextDidEndEditing(_ notice: Notification) {
        if let field = notice.object as? NSTextField { durationChanged(field) }
    }

    func windowWillClose(_ notification: Notification) {
        accessCheck?.invalidate()
        accessCheck = nil
        cancelMicrophone?()
        microphoneDetail.stringValue = ""
        stopVoicePreview?()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    @objc private func keepChanged(_ item: NSButton) {
        prefs.set(item.state == .on, forKey: Preference.keep)
        changed?()
    }

    @objc private func voiceChanged(_ item: NSPopUpButton) {
        guard let voice = choice(item) else { return }
        stopVoicePreview?()
        library.select(voice)
        catalog.selectItem(withTag: Int(voice.rawValue))
        refresh()
    }

    @objc private func previewVoiceClicked() {
        guard let voice = choice(catalog) else { return }
        if let status = previewVoice?(voice) { voiceMessage(status) }
    }

    private func choice(_ popup: NSPopUpButton) -> ReadingVoice? {
        popup.selectedItem.flatMap { UInt8(exactly: $0.tag) }.flatMap(ReadingVoice.init(rawValue:))
    }

    private func voiceMessage(_ text: String) {
        voiceDetail.stringValue = text
        voiceDetail.isHidden = text.isEmpty
    }

    private func refreshVoices() {
        for (picker, language) in [(voices, SpeechLanguage.english), (spanishVoices, .spanish)] {
            picker.removeAllItems()
            for voice in library.enabled where voice.language == language {
                picker.addItem(withTitle: voice.label)
                picker.lastItem?.tag = Int(voice.rawValue)
            }
            if let active = library.selected(for: language) { picker.selectItem(withTag: Int(active.rawValue)) }
            else { picker.addItem(withTitle: "Choose a voice below") }
            picker.isEnabled = library.selected(for: language) != nil
        }
        catalog.isEnabled = !addingVoice
        manageVoice.isEnabled = !addingVoice
        catalogChanged()
    }

    @objc private func catalogChanged() {
        guard let voice = choice(catalog) else { return }
        let enabled = library.enabled.contains(voice)
        let shared = models.location(.reading) != nil
        let hasEngine = !models.candidates(for: .reading, separateVoice: true).isEmpty
        let onDisk = shared || library.standalone(voice) != nil
        manageVoice.title = onDisk ? (enabled ? "Remove…" : "Add Voice") : "Download Voice"
        manageVoice.setAccessibilityLabel(manageVoice.title + " " + voice.label)
        voiceMessage(addingVoice ? "Adding voice…" : hasEngine ? "" : "Samples play offline. Download Kokoro to read your own text.")
    }

    @objc private func browseVoiceChanged() {
        stopVoicePreview?()
        catalogChanged()
    }

    @objc private func manageVoiceClicked() {
        guard !addingVoice, let voice = choice(catalog) else { return }
        if library.enabled.contains(voice), models.location(.reading) != nil || library.standalone(voice) != nil {
            stopVoicePreview?()
            guard allowModelChanges?() != false else { voiceMessage("Finish the current speech task before removing a voice."); return }
            let alert = NSAlert()
            alert.messageText = "Remove \(voice.label)?"
            alert.informativeText = library.owns(voice)
                ? "This deletes the voice file Amapoani downloaded to the shared folder."
                : "This removes the voice from your reading choices. Its shared model stays available to other apps."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Remove")
            guard alert.runModal() == .alertSecondButtonReturn, allowModelChanges?() != false else { return }
            do { try library.remove(voice); modelsChanged?(.reading); refresh() }
            catch { voiceMessage(error.localizedDescription) }
        } else {
            addingVoice = true
            refreshVoices()
            library.add(voice) { [weak self] result in
                guard let self else { return }
                addingVoice = false
                if case .success = result { library.select(voice) }
                refresh()
                if case let .failure(error) = result { voiceMessage(error.localizedDescription) }
            }
        }
    }

    private func updateSpeedLabel(_ slider: NSSlider) {
        speedValue.stringValue = String(format: "%.2f×", slider.doubleValue / 100)
        slider.setAccessibilityValueDescription(speedValue.stringValue)
    }

    @objc private func speedChanged(_ slider: NSSlider) {
        slider.doubleValue = slider.doubleValue.rounded()
        prefs.set(slider.integerValue, forKey: Preference.speed)
        updateSpeedLabel(slider)
    }

    @objc private func upgradeReading() { download(.reading) }

    @objc private func popupChanged(_ item: NSPopUpButton) {
        guard let key = item.identifier?.rawValue else { return }
        prefs.set(item.indexOfSelectedItem, forKey: key)
        if key == Preference.capsulePosition { positionChanged?() }
        else { changed?() }
    }

    @objc private func microphoneKeyChanged(_ button: NSButton) {
        prefs.set(button.state == .on, forKey: Preference.microphoneShortcut)
        changed?()
    }

    @objc private func durationChanged(_ item: NSTextField) {
        guard let key = item.identifier?.rawValue else { return }
        let maximum = key == Preference.reading ? 120 : 60
        guard let value = Int(item.stringValue), (1...maximum).contains(value) else {
            item.stringValue = String(prefs.integer(forKey: key))
            report("Enter between 1 and \(maximum) minutes.")
            return
        }
        prefs.set(value, forKey: key)
        changed?()
    }

    private func choose(search: Bool) {
        guard !addingVoice, downloads.isEmpty, allowModelChanges?() != false else {
            report("Finish the speech task or download before changing folders.")
            return
        }
        let choice = NSOpenPanel()
        choice.canChooseFiles = false
        choice.canChooseDirectories = true
        choice.directoryURL = models.root
        if choice.runModal() == .OK, let url = choice.url {
            guard !addingVoice, downloads.isEmpty, allowModelChanges?() != false else {
                report("Finish the speech task or download before changing folders.")
                return
            }
            prefs.removeObject(forKey: "detachedModels")
            if search {
                var paths = prefs.stringArray(forKey: "modelSearchLocations") ?? []
                if !paths.contains(url.path) { paths.append(url.path) }
                prefs.set(paths, forKey: "modelSearchLocations")
            } else {
                prefs.set(url.path, forKey: Preference.folder)
            }
            report("")
            modelsChanged?(nil)
            refresh()
        }
    }

    @objc private func requestAccessibility() {
        Desktop.requestAccess()
        guard accessCheck == nil else { return }
        accessCheck = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAccess()
        }
        refreshAccess()
    }

    @objc private func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @available(macOS 15.4, *)
    @objc private func setUpCopyFallback() {
        let board = NSPasteboard.general
        let alert = NSAlert()
        alert.messageText = "Use the clipboard for browser integration"
        alert.informativeText = "Amapoani uses Paste to insert dictation into browser text fields and Copy to verify selected text in Firefox and Zen. It checks the target before acting and tries to preserve your clipboard. Set Amapoani to Always Allow in Privacy & Security → Paste from Other Apps."
        if board.accessBehavior == .default {
            alert.informativeText += " Copy a sample word in another app first, then choose Check Clipboard so macOS can list Amapoani."
            alert.addButton(withTitle: "Check Clipboard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // Read only on this explicit request. The sample is discarded immediately.
            _ = board.string(forType: .string)
        } else {
            alert.addButton(withTitle: "Done")
            alert.runModal()
        }
        refreshAccess()
    }

    @objc private func folderClicked() { choose(search: false) }
    @objc private func searchClicked() { choose(search: true) }

    @objc private func modelClicked(_ action: NSButton) {
        guard let name = action.identifier?.rawValue, let model = Model(rawValue: name) else { return }
        if let location = resolvedModels[model] {
            if !models.owns(model, at: location) {
                guard allowModelChanges?() != false else { report("Finish the speech task before detaching a model."); return }
                modelsChanged?(model)
                models.detach(location)
                report("Model detached. The original files are still in the shared folder.")
                refresh()
                return
            }
            guard allowModelChanges?() != false else { report("Finish the speech task before deleting a model."); return }
            let consent = NSAlert()
            consent.messageText = "Delete \(model.label)?"
            consent.informativeText = "This removes the installed files from the shared folder. Other apps may use them."
            consent.addButton(withTitle: "Cancel")
            consent.addButton(withTitle: "Delete")
            if consent.runModal() == .alertSecondButtonReturn {
                guard allowModelChanges?() != false else {
                    report("Finish the speech task before deleting a model.")
                    return
                }
                modelsChanged?(model)
                do { try models.delete(model, at: location); report("Model deleted.") }
                catch { report(error.localizedDescription) }
                refresh()
            }
            return
        }
        download(model)
    }

    @objc private func setupClicked() {
        guard !installingRuntime else { return }
        if models.runtime.libraryDirectory == nil {
            installingRuntime = true
            report("Downloading and verifying the speech runtime…")
            refresh()
            models.runtime.install { [weak self] result in
                guard let self else { return }
                installingRuntime = false
                switch result {
                case .success:
                    report("Speech runtime is ready.")
                    setupClicked()
                case .failure(let error):
                    report(error.localizedDescription)
                }
                refresh()
            }
            return
        }
        [Model.reading, .multilingualDictation].filter { model in
            let separate = model == .reading && [SpeechLanguage.english, .spanish].contains(where: hasSelectedSeparateVoice)
            return models.candidates(for: model, separateVoice: separate).isEmpty
        }.forEach(download)
    }

    private func hasSelectedSeparateVoice(for language: SpeechLanguage) -> Bool {
        library.selected(for: language).flatMap(library.standalone) != nil
    }

    private func download(_ model: Model) {
        guard allowModelChanges?() != false else { report("Finish the speech task before downloading a model."); return }
        guard !downloads.contains(model) else { return }
        downloads.insert(model)
        report("Downloading and verifying \(model.label)…")
        refresh()
        models.install(model) { [weak self] result in
            guard let self else { return }
            downloads.remove(model)
            switch result {
            case .success: report("\(model.label) is ready."); modelsChanged?(model)
            case .failure(let error): report(error.localizedDescription)
            }
            refresh()
        }
    }

    @objc private func microphoneClicked() {
        microphoneDetail.stringValue = "Speak after the microphone is ready."
        microphone? { [weak self] message in self?.microphoneDetail.stringValue = message }
    }
}
