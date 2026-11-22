import AppKit

func editor(in view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView, editor.isEditable { return editor }
    return view.subviews.lazy.compactMap(editor(in:)).first
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ModelError(message) }
}

func finishEvent() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
}

func draftUndo() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let capsule = CapsuleView(frame: window.contentLayoutRect)
    window.contentView = capsule
    capsule.update(Presentation())
    capsule.layoutSubtreeIfNeeded()
    guard let text = editor(in: capsule), let undo = text.undoManager else {
        throw ModelError("The capsule has no editable draft with Undo.")
    }
    text.insertText("Before 😀 after", replacementRange: NSRange(location: 0, length: 0))
    finishEvent()

    var completed = Presentation()
    completed.expanded = true
    completed.draft = "Before 😀 new words after"
    completed.caret = "Before 😀 new words ".utf16.count
    capsule.update(completed, undoableDraft: true)
    finishEvent()
    try require(text.string == completed.draft, "Dictation did not apply to the draft.")
    try require(text.selectedRange().location == completed.caret, "Dictation lost its UTF-16 caret.")
    undo.undo()
    try require(text.string == "Before 😀 after", "One Undo did not restore the original draft.")
    undo.undo()
    try require(text.string.isEmpty, "Dictation erased earlier undo history.")
    undo.redo()
    undo.redo()
    try require(text.string == completed.draft, "Redo did not replay the two edits.")
}

func seekToEnd() throws {
    let track = Track()
    var rate = UInt32(24_000).littleEndian
    var audio = Data(bytes: &rate, count: 4)
    audio.append(Data(repeating: 0, count: 2400 * 4))
    let appended = try track.append(data: audio, range: NSRange(location: 0, length: 1), cap: 1)
    try require(appended && track.end > 0, "Synthetic PCM did not load.")
    track.finishedGenerating = true
    var ended = false
    track.onEnd = { ended = true }
    try track.seek(track.end, resume: false)
    try require(!ended && track.position == track.end, "A paused final-frame seek changed playback state.")
    try track.play()
    try require(ended, "Resume at the final frame failed to complete.")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
do {
    try draftUndo()
    print("draftUndo: passed")
    try seekToEnd()
    print("seekToEnd: passed")
    if CommandLine.arguments.count == 3 {
        let damaged = URL(fileURLWithPath: CommandLine.arguments[1])
        let valid = URL(fileURLWithPath: CommandLine.arguments[2])
        let location = Models().verifiedLocation(.dictation, among: [damaged, valid])
        try require(location == valid, "A damaged model hid the next verified asset.")
        print("verifiedModelFallback: passed")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
