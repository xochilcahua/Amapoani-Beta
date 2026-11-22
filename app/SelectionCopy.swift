import AppKit

enum SelectionCopy {
    private static let clipboardLock = NSLock()
    private static let markerType = NSPasteboard.PasteboardType("local.ahampo.temporary-paste")

    static func capture(from board: NSPasteboard, expected: String? = nil,
                        whileFocused: () -> Bool, copy: () -> Bool) -> String? {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }
        let originalChange = board.changeCount
        guard whileFocused(), let original = snapshot(board), board.changeCount == originalChange,
              whileFocused(), copy() else { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        while board.changeCount == originalChange {
            guard whileFocused(), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let copyChange = board.changeCount
        guard whileFocused() else { return nil }
        guard let text = board.string(forType: .string) else { return nil }
        if let expected,
           text.trimmingCharacters(in: .whitespacesAndNewlines) != expected.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        guard restore(original, on: board, ifUnchanged: copyChange) else { return nil }
        return whileFocused() ? text : nil
    }

    static func withTemporaryText<T>(_ text: String, on board: NSPasteboard,
                                     whileFocused: () -> Bool, _ paste: (() -> Bool) -> T) -> T? {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }
        let item = NSPasteboardItem()
        let marker = UUID().uuidString
        guard item.setString(text, forType: .string), item.setString(marker, forType: markerType) else { return nil }
        let before = board.changeCount
        guard whileFocused(), let original = snapshot(board), board.changeCount == before, whileFocused() else {
            return nil
        }
        let cleared = board.clearContents()
        guard board.changeCount == cleared else { return nil }
        guard board.writeObjects([item]) else {
            _ = restore(original, on: board, ifUnchanged: cleared)
            return nil
        }
        let written = board.changeCount
        func ownsPasteboard() -> Bool {
            board.changeCount == written && board.string(forType: markerType) == marker && board.changeCount == written
        }
        defer {
            if ownsPasteboard() { _ = restore(original, on: board, ifUnchanged: written) }
        }
        guard whileFocused(), ownsPasteboard() else { return nil }
        return paste(ownsPasteboard)
    }

    private static func restore(_ original: [NSPasteboardItem], on board: NSPasteboard, ifUnchanged count: Int) -> Bool {
        guard board.changeCount == count else { return false }
        let cleared = board.clearContents()
        guard board.changeCount == cleared else { return false }
        return original.isEmpty || board.writeObjects(original)
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem]? {
        var remainingBytes = 16 * 1024 * 1024
        var snapshot: [NSPasteboardItem] = []
        for original in board.pasteboardItems ?? [] {
            let item = NSPasteboardItem()
            for type in original.types {
                guard !type.rawValue.localizedCaseInsensitiveContains("promise"),
                      type.rawValue != "org.nspasteboard.ConcealedType",
                      let data = original.data(forType: type), data.count <= remainingBytes,
                      item.setData(data, forType: type) else { return nil }
                remainingBytes -= data.count
            }
            snapshot.append(item)
        }
        return snapshot
    }
}
