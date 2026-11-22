import AppKit

@main
struct SelectionCopyRegression {
    static func main() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let original = NSPasteboardItem()
        let secondary = NSPasteboardItem()
        let binary = Data([0, 17, 128, 255])
        precondition(original.setString("Original clipboard", forType: .string))
        precondition(original.setData(binary, forType: .tiff))
        precondition(secondary.setString("Second item", forType: .string))
        board.clearContents()
        precondition(board.writeObjects([original, secondary]))

        func write(_ text: String) -> Bool {
            board.clearContents()
            return board.setString(text, forType: .string)
        }

        let captured = SelectionCopy.capture(from: board, whileFocused: { true }) {
            write("Fresh selection")
        }
        precondition(captured == "Fresh selection")
        let restored = board.pasteboardItems ?? []
        precondition(restored.count == 2)
        precondition(restored[0].string(forType: .string) == "Original clipboard")
        precondition(restored[0].data(forType: .tiff) == binary)
        precondition(restored[1].string(forType: .string) == "Second item")
        print("Fresh selection returned and all prior clipboard items restored.")

        let originalChange = board.changeCount
        let stale = SelectionCopy.capture(from: board, whileFocused: { true }, copy: { true })
        precondition(stale == nil && board.changeCount == originalChange)
        print("Copy without a new write never used the previous clipboard text.")

        var focused = true
        let moved = SelectionCopy.capture(from: board, whileFocused: { focused }) {
            focused = false
            return write("New clipboard after switching apps")
        }
        precondition(moved == nil)
        precondition(board.string(forType: .string) == "New clipboard after switching apps")
        print("Focus change rejected the result and preserved the later clipboard.")
    }
}
