import AppKit

private func color(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

struct Graphite {
    var dark: Bool
    var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    var shell: NSColor { color(dark ? 0x2a2c31 : 0xf5f6f8) }
    var tint: NSColor { color(dark ? 0x202227 : 0xe5e8ed) }
    var text: NSColor { color(dark ? 0xf3f1ed : 0x242832) }
    var secondary: NSColor { highContrast ? text : color(dark ? 0xb6bac4 : 0x555d6b) }
    var read: NSColor { color(dark ? 0xa2c8fd : 0x2d5599) }
    var readWell: NSColor { color(dark ? 0x29394f : 0xe1ebf9) }
    var spokenPhrase: NSColor {
        color(dark ? (highContrast ? 0x435d7c : 0x344963) : (highContrast ? 0x9cbcea : 0xc0d5f2))
    }
    var mic: NSColor { color(dark ? 0xffa498 : 0x9a3d39) }
    var micWell: NSColor { color(dark ? 0x432f31 : 0xf6e5e6) }
    var preview: NSColor { color(dark ? 0x23252a : 0xebedf1) }
}

final class CapsulePanel: NSPanel {
    static let shadowInset: CGFloat = 16

    convenience init(capsuleFrame: NSRect) {
        self.init(contentRect: Self.includingShadow(capsuleFrame),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }

    var capsuleFrame: NSRect { frame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset) }

    func setCapsuleFrame(_ rect: NSRect, display: Bool) {
        setFrame(Self.includingShadow(rect), display: display)
    }

    private static func includingShadow(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: -shadowInset, dy: -shadowInset)
    }

    var escape: (() -> Void)?
    var confirm: (() -> Bool)?
    var copyTranscript: (() -> Bool)?
    var onCommand: ((CapsuleCommand) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape?() }

    override func sendEvent(_ event: NSEvent) {
        if isKeyWindow, event.type == .keyDown {
            let editor = firstResponder as? DraftEditor
            let modifiers = event.modifierFlags.intersection(CapsuleShortcuts.shortcutModifiers)
            let key = event.charactersIgnoringModifiers
            if editor?.hasMarkedText() != true {
                if key == "\u{1b}", modifiers.isEmpty {
                    if !event.isARepeat { escape?() }
                    return
                }
                if key == "\r" || key == "\u{3}" {
                    let acceptsReturn = modifiers == .command || (modifiers.isEmpty && editor?.isEditable != true)
                    if acceptsReturn && !event.isARepeat && confirm?() == true { return }
                }
                if key == "c", modifiers == .command, editor?.isEditable != true,
                   (editor?.selectedRange().length ?? 0) == 0,
                   copyTranscript?() == true { return }
                if let command = CapsuleShortcuts().command(for: event),
                   editor?.isEditable != true || command.worksInEditor, let onCommand {
                    if !event.isARepeat { onCommand(command) }
                    return
                }
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let draft = firstResponder as? DraftEditor, draft.handleEditShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let draft = firstResponder as? DraftEditor, draft.handleEditShortcut(event) { return }
        super.keyDown(with: event)
    }
}

private final class Control: NSButton {
    var actionBlock: (() -> Void)?
    var passive = true
    override var needsPanelToBecomeKey: Bool { !passive }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { actionBlock?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let actionBlock else { return false }
        DispatchQueue.main.async(execute: actionBlock)
        return true
    }

    func symbol(_ symbol: String, label: String, ink: NSColor, well: NSColor? = nil) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        contentTintColor = ink
        toolTip = label
        setAccessibilityLabel(label)
        layer?.backgroundColor = well?.cgColor
        layer?.cornerRadius = bounds.height / 2
    }
}

private final class TextButton: NSButton {
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        DispatchQueue.main.async { [weak self] in self?.performClick(nil) }
        return true
    }
}

private final class PassageScroll: NSScrollView {
    var userScrolled: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        userScrolled?()
        super.scrollWheel(with: event)
    }
}

private final class DraftEditor: NSTextView {
    var clickLocation: ((Int) -> Void)?
    var activatesApplicationOnEdit = true
    override var needsPanelToBecomeKey: Bool { isEditable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSelectable }

    func handleEditShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if !isEditable {
            guard isSelectable, modifiers == .command else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": selectAll(nil)
            case "c": copy(nil)
            default: return false
            }
            return true
        }
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "a"): selectAll(nil)
        case (.command, "c"): copy(nil)
        case (.command, "x"): cut(nil)
        case (.command, "v"): paste(nil)
        case (.command, "z"): undoManager?.undo()
        case ([.command, .shift], "z"): undoManager?.redo()
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleEditShortcut(event) { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        if isEditable {
            // Editing deliberately transfers keyboard focus. Transport buttons
            // leave the source application active so it retains its selection.
            if activatesApplicationOnEdit { NSApp.activate() }
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        if let clickLocation, !isEditable {
            let point = convert(event.locationInWindow, from: nil)
            clickLocation(characterIndexForInsertion(at: point))
            return
        }
        super.mouseDown(with: event)
    }
}

private final class FlatSliderCell: NSSliderCell {
    private var graphite: Graphite {
        Graphite(dark: controlView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        color(graphite.dark ? 0x555962 : 0xcdd3dc).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        if fraction > 0 {
            graphite.read.setFill()
            let elapsed = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
            NSBezierPath(roundedRect: elapsed, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        graphite.read.setFill()
        let knob = NSRect(x: knobRect.midX - 5.5, y: knobRect.midY - 5.5, width: 11, height: 11)
        NSBezierPath(ovalIn: knob).fill()
    }
}

final class CapsuleView: NSView, NSTextViewDelegate {
    var onAppearanceChanged: (() -> Void)?
    var onAction: ((String) -> Void)?
    var onDraft: ((String, Int?) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onPhrase: ((Int) -> Void)?
    var expansion = CapsuleExpansion.upward {
        didSet {
            guard oldValue != expansion else { return }
            updateExpandSymbol()
            needsLayout = true
            needsDisplay = true
        }
    }

    private let primary = Control(frame: .zero)
    private let secondary = Control(frame: .zero)
    private let expand = Control(frame: .zero)
    private let languageButton = Control(frame: .zero)
    private let copy = Control(frame: .zero)
    private let reviewCopy = Control(frame: .zero)
    private let clear = Control(frame: .zero)
    private let placeholder = NSTextField(labelWithString: "Type or paste a draft")
    private let inlineScroll = NSScrollView()
    private let inlineEditor = DraftEditor()
    private let target = NSTextField(labelWithString: "")
    private let captureTime = NSTextField(labelWithString: "0:00")
    private let status = NSTextField(labelWithString: "")
    private let screenNotice = NSTextField(labelWithString: "")
    private var source = ""
    private let elapsed = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")
    private let scroll = PassageScroll()
    private let passage = DraftEditor()
    private let draftHistory = UndoManager()
    private let transcriptHistory = UndoManager()
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let modes = [Control(frame: .zero), Control(frame: .zero), Control(frame: .zero)]
    private let modeKeys = ["follow", "draft", "compact"]
    private var destination = ""
    private let follow = TextButton(title: "Follow Audio", target: nil, action: nil)
    private var followingAudio = true
    private var previousHighlight: NSRange?
    private let reviewActions = ["discardTranscript", "recordAgain", "editTranscript", "readTranscript", "insert"]
    private let reviewButtons = (0..<5).map { _ in TextButton(frame: .zero) }
    private var reviewing = false
    private var editingTranscript = false
    private var insertingTranscript = false
    private var language = SpeechLanguage.automatic
    private var state = Presentation()
    private var tall = false
    private var updatingText = false
    private var scrollTranscriptToEnd = false

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    private var shellWidth: CGFloat { max(0, bounds.width - 2 * CapsulePanel.shadowInset) }
    private var shellHeight: CGFloat { tall ? CapsulePlacement.expandedHeight : CapsulePlacement.rowHeight }
    private var noticeHeight: CGFloat { screenNotice.isHidden ? 0 : 34 }
    private var shellOffset: CGFloat { expansion == .downward ? noticeHeight : 0 }
    private var bodyOffset: CGFloat { shellOffset + (expansion == .upward ? CapsulePlacement.rowHeight : 0) }
    var rowOffset: CGFloat { shellOffset + (expansion == .downward ? shellHeight - CapsulePlacement.rowHeight : 0) }
    var height: CGFloat { shellHeight + noticeHeight }
    var preferredExpandedHeight: CGFloat { CapsulePlacement.expandedHeight + noticeHeight }

    private var noticeFrame: NSRect {
        let width = min(max(0, shellWidth - 24), screenNotice.intrinsicContentSize.width + 24)
        let y = expansion == .upward ? shellHeight + 6 : 2
        return NSRect(x: (shellWidth - width) / 2, y: y, width: width, height: 26)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Draw the shell inside the panel's transparent shadow margin.
        setBoundsOrigin(NSPoint(x: -CapsulePanel.shadowInset, y: -CapsulePanel.shadowInset))
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.setAccessibilityElement(false)
        target.font = .systemFont(ofSize: 11, weight: .medium)
        target.alignment = .right
        captureTime.alignment = .right
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.lineBreakMode = .byTruncatingTail
        target.lineBreakMode = .byTruncatingTail
        [elapsed, duration, screenNotice, captureTime].forEach { $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
        elapsed.alignment = .right
        screenNotice.lineBreakMode = .byTruncatingTail
        screenNotice.alignment = .center
        screenNotice.font = .systemFont(ofSize: 12)
        passage.isRichText = false
        passage.isEditable = false
        passage.delegate = self
        passage.activatesApplicationOnEdit = false
        passage.allowsUndo = true
        passage.drawsBackground = false
        passage.isVerticallyResizable = true
        passage.isHorizontallyResizable = false
        passage.textContainerInset = NSSize(width: 0, height: 4)
        passage.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        passage.textContainer?.lineFragmentPadding = 0
        passage.textContainer?.widthTracksTextView = true
        passage.textContainer?.heightTracksTextView = false
        passage.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        passage.autoresizingMask = [.width]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = passage
        inlineEditor.delegate = self
        inlineEditor.isRichText = false
        inlineEditor.allowsUndo = true
        inlineEditor.drawsBackground = false
        inlineEditor.isVerticallyResizable = true
        inlineEditor.isHorizontallyResizable = false
        inlineEditor.textContainerInset = NSSize(width: 0, height: 3)
        inlineEditor.textContainer?.lineFragmentPadding = 0
        inlineEditor.textContainer?.widthTracksTextView = true
        inlineEditor.autoresizingMask = [.width]
        inlineEditor.setAccessibilityLabel("Compact Draft")
        inlineScroll.drawsBackground = false
        inlineScroll.borderType = .noBorder
        inlineScroll.documentView = inlineEditor
        scroll.userScrolled = { [weak self] in
            guard let self, state.reading, state.readingView == "follow" else { return }
            followingAudio = false
            follow.isHidden = false
        }
        follow.target = self
        follow.action = #selector(resumeFollowing)
        seek.cell = FlatSliderCell()
        seek.minValue = 0
        seek.maxValue = 1
        seek.doubleValue = 0
        seek.isContinuous = true
        seek.setAccessibilityLabel("Seek")
        seek.target = self
        seek.action = #selector(slid)
        for (index, control) in modes.enumerated() {
            let key = modeKeys[index]
            control.actionBlock = { [weak self] in self?.onAction?(key) }
        }
        for (index, button) in reviewButtons.enumerated() {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.tag = index
            button.target = self
            button.action = #selector(reviewPressed)
        }

        [scroll, status, screenNotice, placeholder, inlineScroll, primary, secondary, expand, languageButton, copy, reviewCopy, clear,
         seek, elapsed, duration, follow, target, captureTime].forEach(addSubview)
        reviewButtons.forEach(addSubview)
        modes.forEach(addSubview)
        primary.actionBlock = { [weak self] in self?.onAction?("primary") }
        secondary.actionBlock = { [weak self] in self?.onAction?("secondary") }
        expand.actionBlock = { [weak self] in self?.onAction?("expand") }
        languageButton.imagePosition = .noImage
        languageButton.setAccessibilityLabel("Speech language")
        languageButton.setAccessibilityHelp("Language for reading and dictation. Press to switch.")
        languageButton.actionBlock = { [weak self] in self?.onAction?("language") }
        copy.actionBlock = { [weak self] in self?.onAction?("copy") }
        reviewCopy.actionBlock = { [weak self] in self?.onAction?("copy") }
        clear.actionBlock = { [weak self] in self?.clearDraft() }
    }

    required init?(coder: NSCoder) { nil }

    private var palette: Graphite { Graphite(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
    private var centerWidth: CGFloat { shellWidth * 0.74 }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(state, notice: screenNotice.stringValue,
               source: source, destination: destination, language: language,
               editingTranscript: editingTranscript, insertingTranscript: insertingTranscript)
        if let previousHighlight { displayHighlight(previousHighlight) }
        onAppearanceChanged?()
    }

    var isEditingDraft: Bool {
        window?.isKeyWindow == true && window?.firstResponder === inlineEditor
    }

    func focusDraft() {
        guard !inlineScroll.isHidden || scroll.documentView === inlineEditor else { return }
        window?.makeKey()
        window?.makeFirstResponder(inlineEditor)
        layoutSubtreeIfNeeded()
        inlineEditor.scrollRangeToVisible(inlineEditor.selectedRange())
    }

    func focusTranscript() {
        guard reviewing, passage.isEditable else { return }
        window?.makeKey()
        window?.makeFirstResponder(passage)
    }

    func clearDraft() {
        focusDraft()
        let range = NSRange(location: 0, length: (inlineEditor.string as NSString).length)
        guard range.length > 0 else { return }
        inlineEditor.breakUndoCoalescing()
        inlineEditor.insertText("", replacementRange: range)
        inlineEditor.breakUndoCoalescing()
    }

    func discardDraftHistory() {
        draftHistory.removeAllActions()
        transcriptHistory.removeAllActions()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard surfacePath.contains(convert(point, from: superview)) else { return nil }
        let hit = super.hitTest(point)
        if let label = hit as? NSTextField, !label.isEditable, !label.isSelectable { return self }
        return hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    func update(_ state: Presentation, notice: String = "",
                source: String = "", destination: String = "", undoableDraft: Bool = false,
                language: SpeechLanguage = .automatic, editingTranscript: Bool = false,
                insertingTranscript: Bool = false) {
        self.destination = destination
        self.source = source
        self.language = language
        self.editingTranscript = editingTranscript
        self.insertingTranscript = insertingTranscript
        if self.state.task != state.task || self.state.readingView != state.readingView ||
            self.state.expanded != state.expanded {
            inlineEditor.breakUndoCoalescing()
        }
        if self.state.task != state.task {
            followingAudio = true
        }
        if previousHighlight != nil && (self.state.task != state.task || !state.reading ||
                                           self.state.readingView != state.readingView) {
            displayHighlight(nil)
        }
        let wasDictating = self.state.dictating
        self.state = state
        let reading = state.reading
        let recovering = !reading && !state.dictating && state.recovery != nil
        reviewing = recovering
        let draftVisible = (!reading && state.expanded && !state.dictating && !recovering) ||
            (reading && state.readingView == "draft")
        tall = reading ? state.readingView != "compact" : state.expanded || state.dictating || state.recovery != nil
        let palette = palette
        let recording = state.dictating
        let pause = state.phase == "playback_paused" || state.phase == "dictation_paused"
        updatingText = true
        if draftVisible && scroll.documentView !== inlineEditor {
            inlineScroll.documentView = nil
            scroll.documentView = inlineEditor
        } else if !draftVisible && inlineScroll.documentView !== inlineEditor {
            scroll.documentView = passage
            inlineScroll.documentView = inlineEditor
        }
        passage.isEditable = recovering && editingTranscript && !insertingTranscript
        passage.isSelectable = reading || recovering
        passage.clickLocation = reading && state.readingView == "follow" ? { [weak self] index in self?.onPhrase?(index) } : nil
        passage.setAccessibilityLabel(reading ? "Follow Along" : recovering ? "Transcript" : "Transcript Preview")
        passage.textColor = palette.text
        passage.font = .systemFont(ofSize: 15)
        let text = reading ? state.snapshot ?? "" : recovering ? state.recovery ?? "" : state.preview
        if passage.string != text {
            if !reading { transcriptHistory.removeAllActions() }
            scrollTranscriptToEnd = recording && (!wasDictating || passage.string.isEmpty ||
                scroll.documentVisibleRect.maxY >= passage.bounds.maxY - 2)
            passage.string = text
        }
        scroll.isHidden = !tall
        let inlineVisible = !tall && !reading && !recording
        inlineScroll.isHidden = !inlineVisible
        placeholder.isHidden = !inlineVisible || !state.draft.isEmpty
        placeholder.textColor = palette.secondary
        inlineEditor.setAccessibilityLabel(draftVisible ? "Draft" : "Compact Draft")
        inlineEditor.textColor = palette.text
        inlineEditor.insertionPointColor = palette.text
        inlineEditor.font = .systemFont(ofSize: 15)
        let draftChanged = inlineEditor.string != state.draft
        if draftChanged {
            if undoableDraft {
                inlineEditor.breakUndoCoalescing()
                inlineEditor.insertText(state.draft, replacementRange: NSRange(location: 0, length: inlineEditor.string.utf16.count))
                inlineEditor.breakUndoCoalescing()
            } else {
                draftHistory.removeAllActions()
                inlineEditor.string = state.draft
            }
        }
        if let caret = state.caret, caret >= 0, caret <= state.draft.utf16.count,
           draftChanged {
            inlineEditor.setSelectedRange(NSRange(location: caret, length: 0))
        }
        updatingText = false
        status.isHidden = !tall || draftVisible
        status.textColor = recording ? palette.mic : reading ? palette.read : palette.secondary
        follow.isHidden = !reading || state.readingView != "follow" || followingAudio
        status.stringValue = recovering ? (editingTranscript ? "Edit transcript" : "Review transcript") :
            recording ? (pause ? "Dictation paused" : state.phase == "finishing" ? "Finishing" : "Listening") :
            state.phase == "loading" ? "Preparing audio" : !notice.isEmpty && reading ? notice : pause ? "Paused · \(source)" : source
        target.isHidden = !recording && !recovering
        target.stringValue = destination
        target.textColor = palette.secondary
        target.setAccessibilityLabel("Dictation destination: " + destination)
        captureTime.isHidden = !recording
        captureTime.textColor = palette.secondary
        updateNotice(notice)
        seek.isHidden = !reading
        seek.toolTip = reading ? source : nil
        seek.setAccessibilityHelp(reading ? source : nil)
        elapsed.isHidden = !reading
        duration.isHidden = !reading
        let symbols = ["text.alignleft", "square.and.pencil", "rectangle.compress.vertical"]
        let names = ["Follow Along", "Edit Draft", "Compact Playback"]
        for (index, control) in modes.enumerated() {
            let selected = modeKeys[index] == state.readingView
            control.isHidden = !reading
            control.symbol(symbols[index], label: names[index],
                           ink: selected ? palette.read : palette.secondary,
                           well: selected ? palette.readWell : nil)
            control.setAccessibilityValue(selected ? "Selected" : "Not selected")
        }
        elapsed.textColor = palette.secondary
        duration.textColor = palette.secondary
        let shortcuts = CapsuleShortcuts()
        if recovering { updateReviewButtons(shortcuts) }
        else { reviewButtons.forEach { $0.isHidden = true } }
        expand.isHidden = reading || recording || state.recovery != nil
        languageButton.isHidden = expand.isHidden
        languageButton.attributedTitle = NSAttributedString(
            string: language.abbreviation,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: palette.secondary])
        languageButton.setAccessibilityValue(language.label)
        languageButton.toolTip = "Speech language: \(language.label). Switch to \(language.next.label)."
        copy.isHidden = !draftVisible
        reviewCopy.isHidden = !recovering
        clear.isHidden = !draftVisible
        copy.isEnabled = !state.draft.isEmpty
        clear.isEnabled = !state.draft.isEmpty
        let primarySymbol = reading || recording ? (pause ? "play.fill" : "pause.fill") : "mic"
        let primaryLabel = reading ? (pause ? "Resume Playback" : "Pause Playback") :
            recording ? (pause ? "Resume Dictation" : "Pause Dictation") : "Start Dictation"
        primary.symbol(primarySymbol, label: primaryLabel, ink: reading ? palette.read : palette.mic,
                       well: reading ? palette.readWell : palette.micWell)
        primary.isEnabled = state.phase != "loading" && state.phase != "finishing" && !notice.hasPrefix("Time limit reached")
        primary.setAccessibilityHelp(reading ? source : recording ? destination : nil)
        if reading, !source.isEmpty { primary.toolTip = primaryLabel + " · " + source }
        if recording, !destination.isEmpty { primary.toolTip = primaryLabel + " · " + destination }
        primary.isHidden = recovering
        if !reading && !recording { primary.toolTip = primaryLabel + " (\(shortcuts.hint(for: .dictate)))" }
        secondary.symbol(reading || recording ? "stop.fill" : "speaker.wave.2",
                         label: reading ? "Stop Playback" : recording ? "Finish Dictation" : "Read Aloud",
                         ink: recording ? palette.mic : palette.read, well: recording ? palette.micWell : palette.readWell)
        secondary.isEnabled = state.phase != "finishing"
        secondary.isHidden = recovering
        if !reading && !recording { secondary.toolTip = "Read Aloud (\(shortcuts.hint(for: .read)))" }
        if recording { secondary.toolTip = "Finish Dictation (↩)" }
        updateExpandSymbol()
        copy.symbol("document.on.document", label: "Copy", ink: palette.secondary)
        reviewCopy.symbol("document.on.document", label: "Copy Transcript", ink: palette.secondary)
        reviewCopy.toolTip = "Copy Transcript (⌘C)"
        clear.symbol("trash", label: "Clear Draft", ink: palette.secondary)
        copy.toolTip = "Copy Draft (\(shortcuts.hint(for: .copyDraft)))"
        clear.toolTip = "Clear Draft (\(shortcuts.hint(for: .clearDraft)))"
        needsLayout = true
        needsDisplay = true
    }

    private func updateExpandSymbol() {
        let pointsUp = (expansion == .upward) != tall
        expand.symbol(pointsUp ? "chevron.up" : "chevron.down",
                      label: tall ? "Collapse Draft" : "Expand Draft", ink: palette.secondary)
        expand.toolTip = (tall ? "Collapse Draft" : "Expand Draft") + " (\(CapsuleShortcuts().hint(for: .toggleDraft)))"
    }

    private func updateReviewButtons(_ shortcuts: CapsuleShortcuts) {
        let labels = ["Discard", "Record Again", "Edit", "Read Aloud", insertingTranscript ? "Inserting…" : "Insert"]
        let keys = ["⎋", shortcuts.hint(for: .dictate), shortcuts.hint(for: .editDraft),
                    shortcuts.hint(for: .read), editingTranscript ? "⌘↩" : "↩"]
        let textIsPresent = !(state.recovery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        reviewCopy.isEnabled = !insertingTranscript && textIsPresent
        let p = palette
        for (index, button) in reviewButtons.enumerated() {
            let isInsert = index == reviewButtons.count - 1
            let label = labels[index]
            button.isHidden = false
            button.isEnabled = !insertingTranscript && (index < 3 || textIsPresent)
            let insertionPlace = destination.hasPrefix("Into ") ? "into " + destination.dropFirst(5) : destination
            button.setAccessibilityLabel(isInsert ? label + " " + insertionPlace : label)
            button.toolTip = label + " (" + keys[index] + ")"
            button.layer?.backgroundColor = (isInsert ? p.readWell : p.tint).cgColor
            let title = NSMutableAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isInsert ? .semibold : .medium),
                .foregroundColor: isInsert ? p.read : p.text
            ])
            title.append(NSAttributedString(string: "  " + keys[index], attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: p.secondary
            ]))
            button.attributedTitle = title
        }
    }

    func updateNotice(_ message: String) {
        screenNotice.isHidden = message.isEmpty || state.reading
        screenNotice.textColor = palette.text
        screenNotice.stringValue = message
        screenNotice.toolTip = message
        needsLayout = true
        needsDisplay = true
    }

    func dictationProgress(_ seconds: Double) { captureTime.stringValue = Self.time(seconds) }

    func progress(current: Double, ready: Double, highlight: NSRange?) {
        seek.maxValue = max(ready, 0.01)
        seek.doubleValue = current
        elapsed.stringValue = Self.time(current)
        duration.stringValue = Self.time(ready)
        if state.reading, state.readingView == "follow", previousHighlight != highlight {
            displayHighlight(highlight)
            if followingAudio, let previousHighlight { passage.scrollRangeToVisible(previousHighlight) }
        }
    }

    private func displayHighlight(_ range: NSRange?) {
        guard let layout = passage.layoutManager else { return }
        let length = passage.string.utf16.count
        if let old = previousHighlight {
            let visible = NSIntersectionRange(old, NSRange(location: 0, length: length))
            if visible.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: visible) }
        }
        previousHighlight = nil
        if let range, range.length > 0, NSMaxRange(range) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: palette.spokenPhrase, forCharacterRange: range)
            previousHighlight = range
        }
    }

    private static func time(_ seconds: Double) -> String {
        let number = max(0, Int(seconds))
        return String(format: "%d:%02d", number / 60, number % 60)
    }

    override func layout() {
        super.layout()
        let width = shellWidth
        let inner = centerWidth
        let x = (width - inner) / 2
        let rowY = rowOffset
        let bodyY = bodyOffset
        primary.frame = NSRect(x: 11, y: rowY + 10, width: 44, height: 44)
        secondary.frame = NSRect(x: width - 55, y: rowY + 10, width: 44, height: 44)
        primary.layer?.cornerRadius = 22
        secondary.layer?.cornerRadius = 22
        expand.frame = NSRect(x: x + inner - 36, y: rowY + 12, width: 34, height: 40)
        languageButton.frame = NSRect(x: x + inner - 79, y: rowY + 12, width: 42, height: 40)
        copy.frame = NSRect(x: x + 8, y: rowY + 12, width: 34, height: 40)
        clear.frame = NSRect(x: x + 44, y: rowY + 12, width: 34, height: 40)
        placeholder.frame = NSRect(x: x + 16, y: rowY + 20, width: max(0, inner - 101), height: 22)
        inlineScroll.frame = NSRect(x: x + 10, y: rowY + 22, width: max(0, inner - 95), height: 22)
        let contentX = x + 20
        let contentWidth = max(0, inner - 40)
        let hasHeader = !status.isHidden || (state.reading && state.readingView == "draft")
        let bodyHeight = CapsulePlacement.expandedHeight - CapsulePlacement.rowHeight
        let contentTop = bodyY + bodyHeight - (hasHeader ? 41 : 14)
        let contentBottom = bodyY + 13
        scroll.frame = NSRect(x: contentX, y: contentBottom,
                              width: contentWidth, height: tall ? contentTop - contentBottom : 0)
        let headerY = bodyY + bodyHeight - 32
        let right = contentX + contentWidth
        let trailing: CGFloat = state.dictating || reviewing ? 154 : !follow.isHidden ? 113 : 0
        status.frame = NSRect(x: contentX, y: headerY, width: max(0, contentWidth - trailing), height: 19)
        target.frame = NSRect(x: right - 149, y: headerY, width: 108, height: 19)
        reviewCopy.frame = NSRect(x: right - 30, y: headerY - 4, width: 30, height: 26)
        captureTime.frame = NSRect(x: right - 34, y: headerY, width: 34, height: 19)
        screenNotice.frame = noticeFrame.insetBy(dx: 10, dy: 4)
        follow.frame = NSRect(x: right - 103, y: headerY - 4, width: 103, height: 25)
        if reviewing {
            let fractions: [CGFloat] = [0.18, 0.23, 0.14, 0.22, 0.23]
            let availableWidth = width - 56
            var left: CGFloat = 16
            for (button, fraction) in zip(reviewButtons, fractions) {
                let buttonWidth = (availableWidth * fraction).rounded(.down)
                button.frame = NSRect(x: left, y: rowY + 14, width: buttonWidth, height: 32)
                left += buttonWidth + 6
            }
        }
        let modeWidth: CGFloat = 32
        let modesStart = x + inner - (modeWidth + 4) * 3
        elapsed.frame = NSRect(x: x + 1, y: rowY + 23, width: 36, height: 17)
        seek.frame = NSRect(x: x + 44, y: rowY + 22, width: max(40, modesStart - x - 94), height: 20)
        duration.frame = NSRect(x: modesStart - 43, y: rowY + 23, width: 40, height: 17)
        for (index, control) in modes.enumerated() {
            control.frame = NSRect(x: modesStart + CGFloat(index) * (modeWidth + 4),
                                   y: rowY + 16, width: modeWidth, height: 32)
            control.layer?.cornerRadius = 8
        }
        if state.reading && state.readingView == "draft" {
            copy.frame = NSRect(x: contentX, y: headerY - 4, width: 32, height: 26)
            clear.frame = NSRect(x: contentX + 36, y: headerY - 4, width: 32, height: 26)
        }
        let draftScroll = scroll.documentView === inlineEditor ? scroll : inlineScroll
        fit(inlineEditor, in: draftScroll)
        if !scroll.isHidden, scroll.documentView === passage {
            fit(passage, in: scroll)
            if scrollTranscriptToEnd {
                scrollTranscriptToEnd = false
                passage.scrollRangeToVisible(NSRange(location: passage.string.utf16.count, length: 0))
            }
        }
    }

    private func fit(_ textView: NSTextView, in scrollView: NSScrollView) {
        let size = scrollView.contentSize
        guard size.width > 0, size.height > 0 else { return }
        textView.minSize = NSSize(width: 0, height: size.height)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        if textView.frame.width != size.width { textView.setFrameSize(NSSize(width: size.width, height: size.height)) }
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            + 2 * textView.textContainerInset.height
        let frameSize = NSSize(width: size.width, height: max(ceil(height), size.height))
        if textView.frame.size != frameSize { textView.setFrameSize(frameSize) }
    }

    private var surfacePath: NSBezierPath {
        let width = shellWidth
        let x = (width - centerWidth) / 2
        let right = width - x
        let shell = NSBezierPath()
        if tall {
            shell.move(to: .init(x: x + 22, y: 220))
            shell.line(to: .init(x: right - 22, y: 220))
            shell.curve(to: .init(x: right, y: 198), controlPoint1: .init(x: right - 8, y: 220), controlPoint2: .init(x: right, y: 212))
            shell.line(to: .init(x: right, y: 81))
            shell.curve(to: .init(x: right + 18, y: 64), controlPoint1: .init(x: right, y: 68), controlPoint2: .init(x: right + 8, y: 64))
            shell.line(to: .init(x: width - 32, y: 64))
            shell.appendArc(withCenter: .init(x: width - 32, y: 32), radius: 32, startAngle: 90, endAngle: -90, clockwise: true)
            shell.line(to: .init(x: 32, y: 0))
            shell.appendArc(withCenter: .init(x: 32, y: 32), radius: 32, startAngle: -90, endAngle: -270, clockwise: true)
            shell.line(to: .init(x: x - 18, y: 64))
            shell.curve(to: .init(x: x, y: 81), controlPoint1: .init(x: x - 8, y: 64), controlPoint2: .init(x: x, y: 68))
            shell.line(to: .init(x: x, y: 198))
            shell.curve(to: .init(x: x + 22, y: 220), controlPoint1: .init(x: x, y: 212), controlPoint2: .init(x: x + 8, y: 220))
            shell.close()
        } else {
            shell.appendRoundedRect(NSRect(x: 0, y: 0, width: width, height: 64), xRadius: 32, yRadius: 32)
        }
        if expansion == .downward {
            shell.transform(using: AffineTransform(m11: 1, m12: 0, m21: 0, m22: -1,
                                                   tX: 0, tY: shellHeight + shellOffset))
        }
        if !screenNotice.isHidden {
            shell.appendRoundedRect(noticeFrame, xRadius: 13, yRadius: 13)
        }
        return shell
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = palette
        let width = shellWidth
        let x = (width - centerWidth) / 2
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(palette.dark ? 0.32 : 0.12)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        palette.shell.setFill()
        surfacePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        if tall {
            let inset = NSRect(x: x + 8, y: shellOffset + (expansion == .upward ? 30 : 8),
                               width: centerWidth - 16, height: 182)
            let contour = NSBezierPath(roundedRect: inset, xRadius: 15, yRadius: 15)
            let angle: CGFloat = expansion == .upward ? 90 : -90
            NSGradient(starting: palette.tint.withAlphaComponent(0), ending: palette.tint)?.draw(in: contour, angle: angle)
        } else if !state.reading {
            palette.preview.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rowOffset + 10, width: centerWidth, height: 44),
                         xRadius: 22, yRadius: 22).fill()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextView, field.isEditable, !updatingText else { return }
        if field === passage {
            state.recovery = field.string
            onTranscript?(field.string)
            updateReviewButtons(CapsuleShortcuts())
            return
        }
        draftChanged(field)
        if !inlineScroll.isHidden { placeholder.isHidden = !field.string.isEmpty }
        copy.isEnabled = !field.string.isEmpty
        clear.isEnabled = !field.string.isEmpty
    }

    func undoManager(for view: NSTextView) -> UndoManager? { view === inlineEditor ? draftHistory : transcriptHistory }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard notification.object as? NSTextView === inlineEditor, inlineEditor.isEditable, !updatingText else { return }
        draftChanged(inlineEditor)
    }

    private func draftChanged(_ field: NSTextView) {
        let caret = NSMaxRange(field.selectedRange())
        state.draft = field.string
        state.caret = caret
        onDraft?(field.string, caret)
    }

    @objc private func resumeFollowing() {
        followingAudio = true
        follow.isHidden = true
        if let previousHighlight { passage.scrollRangeToVisible(previousHighlight) }
    }

    @objc private func slid() { onSeek?(seek.doubleValue) }
    @objc private func reviewPressed(_ button: NSButton) { onAction?(reviewActions[button.tag]) }

}
