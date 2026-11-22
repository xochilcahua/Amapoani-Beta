import AppKit

@main
struct LayoutCheck {
    static func main() {
        _ = NSApplication.shared
        let view = CapsuleView(frame: NSRect(x: 0, y: 0, width: 592, height: 252))
        let long = Array(repeating: "Before the next line, make room for the caret and selection.", count: 80)
            .joined(separator:"\n")
        var normal = Presentation()
        normal.expanded = true
        normal.draft = long
        var recording = normal
        recording.phase = "recording"
        recording.preview = long
        var playback = normal
        playback.phase = "playback_paused"
        playback.snapshot = long
        playback.readingView = "follow"
        var review = normal
        review.recovery = long
        for direction in [CapsuleExpansion.upward, .downward] {
            view.expansion = direction
            for state in [normal, recording, playback, review] {
                view.update(state, source:"Paused selection", destination:"Into Draft")
                view.layoutSubtreeIfNeeded()
                let scrolls = view.subviews.compactMap { $0 as? NSScrollView }.filter { !$0.isHidden }
                precondition(scrolls.count == 1)
                let scroll = scrolls[0]
                let text = scroll.documentView as! NSTextView
                precondition(text.string == long && text.frame.height > scroll.frame.height)
                let top = direction == .upward ? 220.0 : 156.0
                let bottom = direction == .upward ? 64.0 : 0.0
                precondition(scroll.frame.minY >= bottom + 13 && scroll.frame.maxY <= top - 14)
                for label in view.subviews.compactMap({ $0 as? NSTextField }).filter({ !$0.isHidden }) {
                    precondition(!label.frame.intersects(scroll.frame))
                }
                text.scrollRangeToVisible(NSRange(location:long.utf16.count,length:0))
                let layout = text.layoutManager!
                let last = layout.lineFragmentRect(forGlyphAt:layout.numberOfGlyphs-1,effectiveRange:nil)
                let lineBottom = last.maxY + text.textContainerOrigin.y
                precondition(scroll.documentVisibleRect.maxY + 1 >= lineBottom)
            }
        }
        print("Long draft, live dictation, review and paused playback fit in both expansion directions")
    }
}
