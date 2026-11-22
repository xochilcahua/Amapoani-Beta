import AppKit
import ApplicationServices
import Carbon
import OSLog

struct DesktopDestination {
    enum Insertion { case accessibility, paste }

    let app: NSRunningApplication
    let window: AXUIElement
    let field: AXUIElement
    let contents: String
    let range: CFRange
    let insertion: Insertion
}

enum Delivery {
    case confirmed(DesktopDestination?), alreadyPresent, unavailable, uncertain
}

enum DictationTarget {
    case draft, unavailable, field(DesktopDestination)

    var usesRecovery: Bool {
        if case .draft = self { return false }
        return true
    }

    var label: String {
        switch self {
        case .draft: return "Into Draft"
        case .unavailable: return "Keep transcript in Amapoani"
        case .field(let destination): return "Into " + (destination.app.localizedName ?? "original app")
        }
    }
}

final class Desktop {
    enum Selection {
        case text(String)
        case unconfirmedPage(String)
        case empty
        case unavailable
        case permissionRequired
    }

    final class Request {
        private enum State { case pending, cancelled, delivering }
        private let lock = NSLock()
        private var state = State.pending

        var isCancelled: Bool { lock.withLock { state == .cancelled } }

        @discardableResult
        func cancel() -> Bool {
            lock.withLock {
                guard state != .delivering else { return false }
                state = .cancelled
                return true
            }
        }

        func beginDelivery() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .delivering
                return true
            }
        }
    }

    private let selectionQueue = DispatchQueue(label: "local.ahampo.selection", qos: .userInitiated)
    private let invocationQueue = DispatchQueue(label: "local.ahampo.destination", qos: .userInitiated)
    private let log = Logger(subsystem: "local.ahampo.capsule", category: "desktop")
    private var rendererRequests = Set<pid_t>()
    private var preparedGecko = Set<pid_t>()

    static var hasAccess: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        guard !hasAccess else { return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private var lastExternal: NSRunningApplication?
    private var observation: NSObjectProtocol?

    init() {
        remember(NSWorkspace.shared.frontmostApplication)
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notice in
            self?.remember(notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    deinit {
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        lastExternal = app
        // Gecko tracks web selections once its accessibility tree is active.
        // Initialize it on activation so the user can select before summoning Amapoani.
        guard Self.geckoApplications.contains(app.bundleIdentifier ?? ""), Self.hasAccess else { return }
        selectionQueue.async { [weak self] in
            guard let self, !app.isTerminated else { return }
            guard !preparedGecko.contains(app.processIdentifier) else { return }
            preparedGecko.formIntersection(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            if attribute(selectionRoot(for: app), kAXRoleAttribute) as? String == kAXApplicationRole {
                preparedGecko.insert(app.processIdentifier)
            }
        }
    }

    private func target() -> NSRunningApplication? {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != NSRunningApplication.current.processIdentifier {
            remember(current)
            return current
        }
        return lastExternal?.isTerminated == false ? lastExternal : nil
    }

    func selection(request: Request = Request(), _ completion: @escaping (Selection) -> Void) {
        guard let app = target() else { completion(.empty); return }
        selectionQueue.async { [weak self] in
            guard let self else { return }
            let result = selectionForReading(in: app, request: request)
            DispatchQueue.main.async {
                completion(self.target()?.processIdentifier == app.processIdentifier ? result : .unavailable)
            }
        }
    }

    private func selectionForReading(in app: NSRunningApplication, request: Request) -> Selection {
        guard !request.isCancelled, !app.isTerminated else { return .unavailable }
        let root = selectionRoot(for: app)
        var role: CFTypeRef?
        let access = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &role)
        let trusted = Self.hasAccess
        let bundleID = app.bundleIdentifier ?? "unknown"
        log.notice("Selection request for \(bundleID, privacy: .public), trust \(trusted, privacy: .public), role status \(access.rawValue, privacy: .public)")
        if access == .apiDisabled { return .permissionRequired }
        let result = selectedText(in: app, root: root, request: request)
        let expected: String?
        switch result {
        case .unconfirmedPage(let markerText): expected = markerText
        case .unavailable: expected = nil
        default: return result
        }
        guard !request.isCancelled, access == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { return .unavailable }
        let board = NSPasteboard.general
        if #available(macOS 15.4, *), board.accessBehavior != .alwaysAllow { return .unavailable }
        guard let window = element(attribute(root, kAXFocusedWindowAttribute)),
              let field = element(attribute(root, kAXFocusedUIElementAttribute)), !protected(field)
        else { return .unavailable }
        // Gecko can keep the old page text markers after the visible selection is cleared.
        // Verify those markers with the browser's live Copy command.
        let range = selectedRange(field)
        if expected != nil {
            guard containingWebArea(field, in: window) != nil else { return .unavailable }
        } else {
            guard let range, range.location >= 0, range.length > 0 else { return .unavailable }
        }
        guard let action = editAction("C", in: root) else { return .unavailable }
        let text = SelectionCopy.capture(from: board, expected: expected, whileFocused: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let liveWindow = self.element(self.attribute(root, kAXFocusedWindowAttribute)),
                  CFEqual(liveWindow, window),
                  let current = self.element(self.attribute(root, kAXFocusedUIElementAttribute)),
                  CFEqual(current, field)
            else { return false }
            guard expected == nil, let range else { return true }
            guard let liveRange = self.selectedRange(current) else { return false }
            return liveRange.location == range.location && liveRange.length == range.length
        }, copy: {
            !request.isCancelled && AXUIElementPerformAction(action, kAXPressAction as CFString) == .success
        })
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        return .text(text)
    }

    private func editAction(_ key: String, in root: AXUIElement) -> AXUIElement? {
        guard let menuBar = element(attribute(root, kAXMenuBarAttribute)) else { return nil }
        let top = attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for item in top {
            let menus = attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for menu in menus where attribute(menu, kAXRoleAttribute) as? String == kAXMenuRole {
                let actions = attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
                if let copy = actions.first(where: {
                    attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                        (attribute($0, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == key &&
                        (attribute($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0 &&
                        (attribute($0, kAXEnabledAttribute) as? Bool) == true
                }) {
                    return copy
                }
            }
        }
        return nil
    }

    private func selectedText(in app: NSRunningApplication, root: AXUIElement, request: Request) -> Selection {
        let checkPageMarkers = Self.geckoApplications.contains(app.bundleIdentifier ?? "")
        let first = selection(in: root, checkPageMarkers: checkPageMarkers)
        guard case .unavailable = first else { return first }

        if Self.chromiumApplications.contains(app.bundleIdentifier ?? "") {
            rendererRequests.formIntersection(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            if !rendererRequests.contains(app.processIdentifier) {
                // Chromium may enable its renderer before AppKit reports the AX result.
                let result = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                if result == .success {
                    rendererRequests.insert(app.processIdentifier)
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 2.5
            repeat {
                if request.isCancelled { return .unavailable }
                Thread.sleep(forTimeInterval: 0.18)
                let result = selection(in: root, checkPageMarkers: checkPageMarkers)
                if case .unavailable = result { continue }
                return result
            } while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline
            return .unavailable
        }

        Thread.sleep(forTimeInterval: 0.07)
        return selection(in: root, checkPageMarkers: checkPageMarkers)
    }

    private static let chromiumApplications: Set<String> = [
        "net.imput.helium", "org.chromium.Chromium", "com.google.Chrome",
        "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"
    ]
    private static let geckoApplications: Set<String> = [
        "app.zen-browser.zen", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly"
    ]

    private func selectionRoot(for app: NSRunningApplication) -> AXUIElement {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        return root
    }

    private func selection(in root: AXUIElement, checkPageMarkers: Bool) -> Selection {
        let field = element(attribute(root, "AXFocusedUIElement"))
        if let field {
            if protected(field) { return .empty }
            let role = attribute(field, kAXRoleAttribute) as? String ?? ""
            let isTextField = [kAXTextFieldRole, kAXTextAreaRole, "AXSearchField", kAXComboBoxRole].contains(role)
            if let text = attribute(field, "AXSelectedText") as? String, !text.isEmpty {
                return checkPageMarkers && !isTextField ? .unconfirmedPage(text) : .text(text)
            }
            if isTextField {
                if var range = selectedRange(field), range.location >= 0, range.length >= 0 {
                    if range.length == 0 { return .empty }
                    if let encoded = AXValueCreate(.cfRange, &range) {
                        var text: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(
                            field, kAXStringForRangeParameterizedAttribute as CFString, encoded, &text
                        ) == .success, let text = text as? String, !text.isEmpty {
                            return .text(text)
                        }
                    }
                    if case let .text(text) = webSelection(in: field) { return .text(text) }
                    return .unavailable
                }
                return webSelection(in: field)
            }
        }
        guard let window = element(attribute(root, "AXFocusedWindow")) else { return .unavailable }
        let web = field.flatMap { containingWebArea($0, in: window) } ?? visibleWebArea(in: window)
        guard let web else { return .unavailable }
        let selected = webSelection(in: web)
        if checkPageMarkers, case .text(let text) = selected { return .unconfirmedPage(text) }
        return selected
    }

    private func webSelection(in node: AXUIElement) -> Selection {
        var markerRange: CFTypeRef?
        let markerStatus = AXUIElementCopyAttributeValue(node, "AXSelectedTextMarkerRange" as CFString, &markerRange)
        if markerStatus == .success, let markerRange {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                node, "AXStringForTextMarkerRange" as CFString, markerRange, &value
            ) == .success, let text = value as? String {
                return text.isEmpty ? .empty : .text(text)
            }
        }
        var plainText: CFTypeRef?
        let textStatus = AXUIElementCopyAttributeValue(node, kAXSelectedTextAttribute as CFString, &plainText)
        if textStatus == .success, let text = plainText as? String {
            return text.isEmpty ? .empty : .text(text)
        }
        if markerRange == nil, markerStatus == .noValue || textStatus == .noValue { return .empty }
        return .unavailable
    }

    func captureInvocation(_ completion: @escaping (DictationTarget) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else { completion(.draft); return }
        invocationQueue.async { [weak self] in
            guard let self else { return }
            let captured: DictationTarget
            if let focus = focusedDestination(in: app, timeout: 0.4), isTextField(focus.field) {
                captured = destination(in: app, window: focus.window, field: focus.field).map(DictationTarget.field) ?? .unavailable
            } else {
                captured = .draft
            }
            DispatchQueue.main.async {
                if captured.usesRecovery, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    completion(.unavailable)
                } else {
                    completion(captured)
                }
            }
        }
    }

    private func focusedDestination(in app: NSRunningApplication, timeout: Float)
        -> (window: AXUIElement, field: AXUIElement)? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, timeout)
        var values: CFArray?
        let names = ["AXRole", "AXFocusedWindow", "AXFocusedUIElement"]
        if AXUIElementCopyMultipleAttributeValues(root, names as CFArray, [], &values) == .success,
           let result = values as? [CFTypeRef], result.count == names.count,
           let window = element(result[1]), let field = element(result[2]) {
            return (window, field)
        }
        guard let window = element(attribute(root, kAXFocusedWindowAttribute)),
              let field = element(attribute(root, kAXFocusedUIElementAttribute)) else { return nil }
        return (window, field)
    }

    private func destination(in app: NSRunningApplication, window: AXUIElement,
                             field: AXUIElement) -> DesktopDestination? {
        guard isTextField(field), let contents = attribute(field, kAXValueAttribute) as? String,
              let range = selectedRange(field) ?? (contents.isEmpty ? CFRange(location: 0, length: 0) : nil),
              range.location >= 0, range.length >= 0,
              range.location <= contents.utf16.count,
              range.length <= contents.utf16.count - range.location else { return nil }
        let insertion: DesktopDestination.Insertion
        if containingWebArea(field, in: window) != nil {
            guard writable(field, attribute: kAXValueAttribute) else { return nil }
            if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior != .alwaysAllow { return nil }
            insertion = .paste
        } else {
            guard writable(field, attribute: kAXSelectedTextAttribute) else { return nil }
            insertion = .accessibility
        }
        return DesktopDestination(app: app, window: window, field: field, contents: contents, range: range,
                                  insertion: insertion)
    }

    private func isTextField(_ field: AXUIElement) -> Bool {
        guard !protected(field), let role = attribute(field, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, "AXSearchField", kAXComboBoxRole].contains(role) else { return false }
        return (attribute(field, kAXEnabledAttribute) as? Bool) != false
    }

    private func writable(_ field: AXUIElement, attribute name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(field, name as CFString, &settable) == .success && settable.boolValue
    }

    func deliver(_ transcript: String, to original: DesktopDestination, request: Request,
                 _ completion: @escaping (Delivery) -> Void) {
        invocationQueue.async { [self] in
            let result = deliver(transcript, to: original, request: request)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func deliver(_ transcript: String, to original: DesktopDestination, request: Request? = nil) -> Delivery {
        let app = original.app
        func hasOriginalFocus() -> Bool {
            request?.isCancelled != true && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }
        func originalFieldStillFocused() -> Bool {
            guard hasOriginalFocus(), let focus = focusedDestination(in: app, timeout: 0.15) else { return false }
            return CFEqual(focus.window, original.window) && CFEqual(focus.field, original.field) && hasOriginalFocus()
        }
        func revalidate() -> Bool {
            guard hasOriginalFocus(), let focus = focusedDestination(in: app, timeout: 0.25),
                  CFEqual(focus.window, original.window), CFEqual(focus.field, original.field),
                  let current = destination(in: app, window: focus.window, field: focus.field)
            else { return false }
            return current.insertion == original.insertion && current.contents.utf16.elementsEqual(original.contents.utf16)
                && current.range.location == original.range.location && current.range.length == original.range.length
                && originalFieldStillFocused()
        }

        guard revalidate() else { return .unavailable }
        let outgoing = (original.contents as NSString).replacingCharacters(
            in: NSRange(location: original.range.location, length: original.range.length), with: transcript)
        guard !outgoing.utf16.elementsEqual(original.contents.utf16) else { return .alreadyPresent }

        func confirm(_ status: AXError) -> Delivery {
            if [.apiDisabled, .invalidUIElement, .attributeUnsupported, .actionUnsupported].contains(status) {
                return .unavailable
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.65
            repeat {
                if let value = attribute(original.field, kAXValueAttribute) as? String,
                   value.utf16.elementsEqual(outgoing.utf16) {
                    let end = original.range.location + transcript.utf16.count
                    guard let caret = selectedRange(original.field), caret.location == end, caret.length == 0 else {
                        return .confirmed(nil)
                    }
                    return .confirmed(DesktopDestination(app: app, window: original.window, field: original.field,
                                                         contents: value, range: caret, insertion: original.insertion))
                }
                Thread.sleep(forTimeInterval: 0.03)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return .uncertain
        }
        guard hasOriginalFocus() else { return .unavailable }
        if original.insertion == .paste {
            let root = selectionRoot(for: app)
            return SelectionCopy.withTemporaryText(transcript, on: NSPasteboard.general, whileFocused: hasOriginalFocus) { ownsPasteboard in
                guard let paste = self.editAction("V", in: root), revalidate(), ownsPasteboard(),
                      request?.beginDelivery() != false else {
                    return Delivery.unavailable
                }
                return confirm(AXUIElementPerformAction(paste, kAXPressAction as CFString))
            } ?? .unavailable
        }
        guard originalFieldStillFocused(), request?.beginDelivery() != false else { return .unavailable }
        return confirm(AXUIElementSetAttributeValue(original.field, kAXSelectedTextAttribute as CFString, transcript as CFString))
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func selectedRange(_ field: AXUIElement) -> CFRange? {
        guard let raw = attribute(field, "AXSelectedTextRange"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) ? range : nil
    }

    private func protected(_ field: AXUIElement) -> Bool {
        (attribute(field, "AXSubrole") as? String) == "AXSecureTextField"
    }

    private func containingWebArea(_ field: AXUIElement, in window: AXUIElement) -> AXUIElement? {
        var node = field
        for _ in 0..<16 {
            if CFEqual(node, window) { break }
            if (attribute(node, "AXRole") as? String) == "AXWebArea" { return node }
            guard let parent = element(attribute(node, "AXParent")) else { break }
            node = parent
        }
        return nil
    }

    private func visibleWebArea(in window: AXUIElement) -> AXUIElement? {
        guard let bounds = frame(of: window) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var pending = [window]
        var index = 0
        var page: AXUIElement?
        var area: CGFloat = 0
        while index < min(pending.count, 220), ProcessInfo.processInfo.systemUptime < deadline {
            let node = pending[index]
            index += 1
            if (attribute(node, "AXHidden") as? Bool) == true { continue }
            if (attribute(node, "AXRole") as? String) == "AXWebArea" {
                if let visible = frame(of: node)?.intersection(bounds), !visible.isNull,
                   visible.width * visible.height > area {
                    page = node
                    area = visible.width * visible.height
                }
                continue
            }
            let children = attribute(node, "AXVisibleChildren") as? [AXUIElement] ??
                attribute(node, "AXChildren") as? [AXUIElement] ?? []
            pending.append(contentsOf: children.prefix(220 - pending.count))
        }
        return page
    }

    private func frame(of node: AXUIElement) -> CGRect? {
        guard let position = attribute(node, "AXPosition"), let size = attribute(node, "AXSize"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}

final class Shortcut {
    private static let signature: OSType = 0x4148414d
    private static let keyboardShortcutID: UInt32 = 1
    private static let microphoneShortcutID: UInt32 = 2
    private var hotKey: EventHotKeyRef?
    private var microphoneKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var currentOption: Int?
    private let action: () -> Void
    private let microphoneAction: () -> Void

    init(_ action: @escaping () -> Void, microphoneAction: @escaping () -> Void) {
        self.action = action
        self.microphoneAction = microphoneAction
        let types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr, hotKeyID.signature == Shortcut.signature else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<Shortcut>.fromOpaque(pointer).takeUnretainedValue()
            if hotKeyID.id == Shortcut.keyboardShortcutID && GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                shortcut.action()
            } else if hotKeyID.id == Shortcut.microphoneShortcutID && GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                shortcut.microphoneAction()
            }
            return noErr
        }, types.count, types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let microphoneKey { UnregisterEventHotKey(microphoneKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func bind(_ option: Int) -> Bool {
        guard handler != nil else { return false }
        if option == currentOption, hotKey != nil { return true }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let modifier = option == 1 ? controlKey : optionKey
        currentOption = option
        return RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(modifier | shiftKey),
            EventHotKeyID(signature: Self.signature, id: Self.keyboardShortcutID),
            GetApplicationEventTarget(), 0, &hotKey
        ) == noErr
    }

    func bindMicrophoneKey(_ enabled: Bool) -> Bool {
        if !enabled {
            if let microphoneKey { UnregisterEventHotKey(microphoneKey) }
            microphoneKey = nil
            return true
        }
        guard handler != nil else { return false }
        if microphoneKey != nil { return true }
        return RegisterEventHotKey(
            UInt32(kVK_F13), 0, EventHotKeyID(signature: Self.signature, id: Self.microphoneShortcutID),
            GetApplicationEventTarget(), 0, &microphoneKey
        ) == noErr
    }
}
