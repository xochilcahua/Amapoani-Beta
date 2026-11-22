import AppKit
import ApplicationServices
import CryptoKit

let browserIDs = [
    "zen": "app.zen-browser.zen",
    "safari": "com.apple.Safari",
    "helium": "net.imput.helium",
    "chrome": "com.google.Chrome",
    "firefox": "org.mozilla.firefox"
]
let marker = "AHAMPO Journey Fixture 7d2792"
let fixtureSelections = [
    "page-a": ("Select Page A", "Amber lanterns mark the first harbor. Seven boats wait beside the pier while the evening tide comes in."),
    "page-b": ("Select Page B", "Violet ribbons line the second harbor. Two quiet boats carry blankets across the water before sunrise."),
    "textarea": ("Select Textarea", "Silver kites circle the meadow. This sentence comes from the editable field only."),
    "none": ("Clear Page Selection", "")
]
let draftText = """
Copper bells ring above the village square. Beyond the square, a garden path follows the shaded bank of the river. The path passes a row of wooden benches and a stone bridge. A baker wraps the morning bread in paper, and a cyclist carries a basket of apples toward the market. By noon the clouds have moved east, leaving the river and the wheat fields bright with sunlight. The last bell rings when the shop closes, and the village grows quiet.
"""
let draftEdit = " Added during playback."
let noticeActions = ["Read Draft", "Allow Access", "Allow Accessibility", "Dismiss Message"]
let capsuleMarkers = ["Read Aloud", "Stop Playback", "Finish Dictation", "Stop Dictation", "Cancel Dictation"]
let caseIDs = ["layout", "empty", "fresh-page", "reselect", "textarea", "deselection", "wake", "reopen", "unavailable", "transport", "edit-undo"]
let command: CGEventFlags = .maskCommand

struct Problem: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func need(_ condition: Bool, _ message: String) throws {
    if !condition { throw Problem(message) }
}

func waitFor<T>(_ label: String, seconds: TimeInterval = 4, _ read: () throws -> T?) throws -> T {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if let value = try read() { return value }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw Problem(label)
}

func sleepFor(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
func sha(_ url: URL) throws -> String {
    try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func ax(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, key as CFString, &result) == .success else { return nil }
    return result
}

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func str(_ node: AXUIElement, _ key: String) -> String {
    ax(node, key) as? String ?? ""
}

func nodes(_ root: AXUIElement) -> [AXUIElement] {
    var queue = [root]
    var index = 0
    while index < queue.count && queue.count < 1000 {
        queue.append(contentsOf: (ax(queue[index], "AXChildren") as? [AXUIElement] ?? []).prefix(100))
        index += 1
    }
    return queue
}

func names(_ node: AXUIElement) -> [String] {
    ["AXTitle", "AXDescription", "AXIdentifier"].map { str(node, $0) }.filter { !$0.isEmpty }
}

func named(_ nodes: [AXUIElement], _ name: String, role: String? = nil) -> AXUIElement? {
    nodes.first { names($0).contains(name) && (role == nil || str($0, "AXRole") == role) }
}

func rect(_ node: AXUIElement) -> CGRect? {
    guard let pointValue = ax(node, "AXPosition"), CFGetTypeID(pointValue) == AXValueGetTypeID(),
          let sizeValue = ax(node, "AXSize"), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pointValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func pid(_ node: AXUIElement) -> pid_t {
    var value: pid_t = 0
    AXUIElementGetPid(node, &value)
    return value
}

func hierarchy(_ node: AXUIElement) -> [AXUIElement] {
    var chain = [node]
    while chain.count < 16, let last = chain.last, let parent = element(ax(last, "AXParent")) {
        if chain.contains(where: { CFEqual($0, parent) }) { break }
        chain.append(parent)
    }
    return chain
}

func mouse(_ node: AXUIElement, label: String, pid expectedPID: pid_t, visible: CGRect? = nil,
           within: [AXUIElement] = []) throws {
    guard let bounds = visible ?? rect(node), !bounds.isEmpty, !bounds.isNull else {
        throw Problem("Missing visible bounds for \(label).")
    }
    let offsets: [(CGFloat, CGFloat)] = within.isEmpty ? [(0.5, 0.5)] :
        [(0.5, 0.5), (0.25, 0.5), (0.75, 0.5), (0.5, 0.25), (0.5, 0.75)]
    let system = AXUIElementCreateSystemWide()
    let point = offsets.lazy.map { x, y in
        CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
    }.first { position in
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(position.x), Float(position.y), &hit) == .success,
              let hit, pid(hit) == expectedPID else { return false }
        if within.isEmpty { return true }
        let chain = hierarchy(hit)
        return within.contains { ancestor in chain.contains { CFEqual($0, ancestor) } }
    }
    guard let point else { throw Problem("\(label) is covered or outside the intended control.") }
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw Problem("Could not create a physical mouse click.") }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    down.post(tap: .cghidEventTap)
    sleepFor(0.06)
    up.post(tap: .cghidEventTap)
}

func key(_ code: CGKeyCode, flags: CGEventFlags = [], unicode: [UInt16] = []) throws {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
            throw Problem("Could not create a keyboard event.")
        }
        event.flags = flags
        if !unicode.isEmpty { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
        event.post(tap: .cghidEventTap)
    }
    sleepFor(0.10)
}

struct Result: Codable {
    let id: String
    let status: String
    let evidence: [String]
}

struct Report: Codable {
    let candidate: String
    let sha256: String
    let fixtureSHA256: String
    let target: String
    let mode: String
    let started: String
    var candidatePID: pid_t?
    var browserPID: pid_t?
    var osVersion: String?
    var browserVersion: String?
    var results: [Result] = []
}

struct Configuration {
    let candidate: URL
    let expectedSHA: String
    let fixture: URL
    let target: String
    let mode: String
    let output: URL

    init(_ args: [String]) throws {
        try need(args.count == 7 && args.first == "--live", "Usage: journey --live CANDIDATE.app EXECUTABLE_SHA256 FIXTURE.html TARGET granted|unavailable NEW_REPORT_DIRECTORY")
        for i in [1, 3, 6] {
            try need(args[i].hasPrefix("/"), "Candidate, fixture and report paths must be absolute.")
        }
        try need(args[2].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "Supply the approved executable SHA-256.")
        try need(browserIDs[args[4]] != nil, "Target must be zen, safari, helium, chrome, or firefox.")
        try need(["granted", "unavailable"].contains(args[5]), "Mode must be granted or unavailable.")
        candidate = canonical(URL(fileURLWithPath: args[1]))
        try need(candidate.pathExtension == "app", "Select an explicit AHAMPO app bundle.")
        expectedSHA = args[2]
        fixture = canonical(URL(fileURLWithPath: args[3]))
        try need(fixture.lastPathComponent == "browser.html", "Select this suite's browser.html.")
        target = args[4]
        mode = args[5]
        output = URL(fileURLWithPath: args[6])
    }
}

final class Journey {
    let config: Configuration
    let candidateBundleID: String
    let executable: URL
    let app: NSRunningApplication
    let browser: NSRunningApplication
    let appAX: AXUIElement
    let browserAX: AXUIElement
    var facts: [String] = []
    var ownedDrafts: Set<String> = [""]
    var startedPlayback = false

    init(_ config: Configuration) throws {
        guard let bundle = Bundle(url: config.candidate), let id = bundle.bundleIdentifier,
              let executable = bundle.executableURL else { throw Problem("Candidate bundle metadata is unavailable.") }
        try need(executable.lastPathComponent == "AHAMPO", "Candidate executable must be AHAMPO.")
        try need(try sha(executable) == config.expectedSHA, "Candidate executable SHA-256 differs.")
        try need(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "Runner requires live Accessibility and event-posting access.")
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", config.candidate.path]
        try verify.run()
        verify.waitUntilExit()
        try need(verify.terminationStatus == 0, "Candidate signature failed strict verification.")
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        guard instances.count == 1, let app = instances.first,
              app.bundleURL.map(canonical) == config.candidate,
              app.executableURL.map(canonical) == canonical(executable) else {
            throw Problem("Launch the exact candidate and keep one running instance.")
        }
        guard let browser = NSWorkspace.shared.frontmostApplication,
              browser.bundleIdentifier == browserIDs[config.target] else {
            throw Problem("Bring the selected browser's fixture tab to the front.")
        }
        self.config = config
        self.candidateBundleID = id
        self.executable = canonical(executable)
        self.app = app
        self.browser = browser
        self.appAX = AXUIElementCreateApplication(app.processIdentifier)
        self.browserAX = AXUIElementCreateApplication(browser.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 0.75)
        AXUIElementSetMessagingTimeout(browserAX, 0.75)
        try guardCandidate()
        _ = try fixtureWindow()
        try need((ax(appAX, "AXWindows") as? [AXUIElement])?.count == 1, "Show only the ordinary capsule and close candidate Settings.")
        try need(control("Read Aloud") != nil, "Show an idle standard capsule.")
        try need(try draftValue().isEmpty, "Use an empty disposable draft. The runner left the draft untouched.")
    }

    func guardCandidate() throws {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: candidateBundleID)
        try need(instances.count == 1 && instances.first?.processIdentifier == app.processIdentifier &&
                 instances.first?.bundleURL.map(canonical) == config.candidate &&
                 instances.first?.executableURL.map(canonical) == executable && !app.isTerminated,
                 "Candidate process identity changed.")
        let changed = try executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let changed, let launched = app.launchDate {
            try need(changed.timeIntervalSince(launched) < 1, "Candidate executable changed after launch.")
        }
        try need(try sha(executable) == config.expectedSHA, "Candidate executable SHA-256 changed.")
    }

    func fixtureWindow(requireFront: Bool = true) throws -> AXUIElement {
        if requireFront {
            try need(NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier, "Expected the disposable fixture browser to remain frontmost.")
        }
        let focused = element(ax(browserAX, "AXFocusedWindow"))
        let windows = ax(browserAX, "AXWindows") as? [AXUIElement] ?? []
        let matching = windows.filter { str($0, "AXTitle").contains(marker) }
        guard let window = (requireFront ? focused : matching.count == 1 ? matching.first : nil),
              str(window, "AXTitle").contains(marker) else { throw Problem("The fixture browser's active document is required.") }
        let locationNodes = [window] + nodes(window).filter { str($0, "AXRole") == "AXWebArea" }
        let locations = locationNodes.flatMap { node in
            ["AXURL", "AXDocument"].compactMap { label -> URL? in
                let value = ax(node, label)
                if let url = value as? URL { return url }
                if let string = value as? String { return URL(string: string) }
                return nil
            }
        }
        try need(locations.contains { $0.isFileURL && canonical($0) == config.fixture }, "Accessibility could not verify the exact local fixture URL.")
        try need(named(nodes(window), "Select Page A", role: "AXButton") != nil, "Fixture controls are unavailable.")
        return window
    }

    func capsule() -> AXUIElement? {
        let windows = ax(appAX, "AXWindows") as? [AXUIElement] ?? []
        return windows.first { window in
            capsuleMarkers.contains { name in named(nodes(window), name, role: "AXButton") != nil }
        }
    }

    func capsuleNodes() -> [AXUIElement] { capsule().map(nodes) ?? [] }

    func control(_ name: String, role: String = "AXButton") -> AXUIElement? {
        named(capsuleNodes(), name, role: role)
    }

    func click(_ name: String) throws {
        try guardCandidate()
        guard let node = control(name) else { throw Problem("Missing capsule control \(name).") }
        try mouse(node, label: name, pid: app.processIdentifier)
    }

    func draft() throws -> AXUIElement {
        let candidates = capsuleNodes()
        guard let draft = named(candidates, "Compact Draft", role: "AXTextArea") ??
                named(candidates, "Draft", role: "AXTextArea") else { throw Problem("Draft editor is unavailable.") }
        return draft
    }

    func draftValue() throws -> String {
        let node = try draft()
        guard let value = ax(node, "AXValue") as? String else { throw Problem("Draft text could not be checked.") }
        return value
    }

    func focusDraft() throws {
        try guardCandidate()
        let editor = try draft()
        guard let window = capsule(), let windowBounds = rect(window), let editorBounds = rect(editor) else {
            throw Problem("The capsule's draft has no visible bounds.")
        }
        let scrollAreas = nodes(window).filter { node in
            str(node, "AXRole") == "AXScrollArea" && nodes(node).contains { CFEqual($0, editor) }
        }
        let viewport = scrollAreas.compactMap(rect).reduce(windowBounds.intersection(editorBounds)) {
            $0.intersection($1)
        }
        try mouse(editor, label: "draft", pid: app.processIdentifier, visible: viewport, within: [editor] + scrollAreas)
        _ = try waitFor("Physical click did not focus the candidate's draft.") {
            let focused = element(ax(self.appAX, "AXFocusedUIElement"))
            return focused.map { CFEqual($0, editor) } == true ? true : nil
        }
    }

    func type(_ text: String, after base: String) throws {
        var current = base
        var remainder = text[...]
        while !remainder.isEmpty {
            try guardKeyboardTarget()
            let chunk = remainder.prefix(12)
            for character in chunk {
                current.append(character)
                ownedDrafts.insert(current)
            }
            try key(0, unicode: Array(chunk.utf16))
            remainder = remainder.dropFirst(chunk.count)
        }
        try need(try draftValue() == current, "The native editor did not preserve the exact typed text.")
    }

    func prepare(_ state: String) throws {
        guard let (button, _) = fixtureSelections[state] else { throw Problem("Unknown fixture state.") }
        let fixtureWindow = try fixtureWindow(requireFront: false)
        browser.activate(options: [])
        sleepFor(0.20)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != browser.processIdentifier {
            guard let node = named(nodes(fixtureWindow), button, role: "AXButton") else {
                throw Problem("Fixture button is unavailable.")
            }
            try mouse(node, label: button, pid: browser.processIdentifier)
            try waitForBrowser()
        }
        let window = try self.fixtureWindow()
        guard let node = named(nodes(window), button, role: "AXButton") else { throw Problem("Fixture button is unavailable.") }
        try mouse(node, label: button, pid: browser.processIdentifier)
        try verifySelection(state)
    }

    func verifySelection(_ state: String) throws {
        let target = marker + " | " + state
        _ = try waitFor("Fixture did not report selection state \(state).") {
            str(try self.fixtureWindow(), "AXTitle").contains(target) ? true : nil
        }
    }

    func waitForBrowser() throws {
        _ = try waitFor("The fixture browser did not come to the front.") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == self.browser.processIdentifier ? true : nil
        }
    }

    func announce(_ event: String) { facts.append(event) }

    func speaker(_ state: String) throws {
        try verifySelection(state)
        let before = try fixtureWindow()
        try need(control("Stop Playback") == nil, "An earlier playback task is active.")
        startedPlayback = true
        try click("Read Aloud")
        sleepFor(0.25)
        try verifySelection(state)
        try need(CFEqual(try fixtureWindow(), before), "Speaker changed the active browser window.")
        announce("One screen-coordinate mouse down/up on Read Aloud. The same fixture remained frontmost in state \(state).")
    }

    func noPermissionAction() throws {
        let all = capsuleNodes()
        try need(!all.contains { node in
            str(node, "AXRole") == "AXMenu" ||
            names(node).contains { name in noticeActions.contains { name.hasPrefix($0) } }
        }, "Speaker exposed an additional menu, draft action, permission action, or status button.")
        try need((ax(appAX, "AXWindows") as? [AXUIElement])?.count == 1, "Speaker opened an additional window.")
    }

    func checkSnapshot(_ expected: String) throws {
        let spoken: AXUIElement = try waitFor("No playback with the exact expected Follow Along passage appeared.", seconds: 25) {
            guard self.control("Stop Playback") != nil,
                  let node = self.control("Follow Along", role: "AXTextArea"),
                  str(node, "AXValue") == expected else { return nil }
            return node
        }
        var editable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(spoken, "AXValue" as CFString, &editable)
        try need(status == .success && !editable.boolValue, "The spoken snapshot must be read-only.")
        try noPermissionAction()
        announce("Exact read-only Follow Along passage: \(expected)")
    }

    func stop() throws {
        try click("Stop Playback")
        _ = try waitFor("Stop did not return to the standard capsule.") {
            self.control("Read Aloud") != nil && self.control("Stop Playback") == nil ? true : nil
        }
        startedPlayback = false
        try need(try draftValue() == draftText, "The exact independent draft changed.")
        announce("Stop returned to the ordinary capsule and the synthetic draft remained exact.")
    }

    func selectionRead(_ state: String) throws {
        try prepare(state)
        try speaker(state)
        try checkSnapshot(fixtureSelections[state]!.1)
        try stop()
    }

    func layout() throws {
        guard let expand = control("Expand Draft"), let compact = rect(try draft()),
              let expandBounds = rect(expand) else { throw Problem("Compact draft or Expand is missing.") }
        try need(compact.height <= max(42, expandBounds.height + 12), "Compact draft exceeds one line.")
        try need(control("Copy") == nil && control("Clear Draft") == nil, "Compact exposes Copy or Clear Draft.")
        let before = try draftValue()
        try click("Expand Draft")
        let collapse: AXUIElement = try waitFor("Collapse did not appear after expansion.") { self.control("Collapse Draft") }
        guard let window = capsule(), let row = rect(window), let chevron = rect(collapse),
              let copy = control("Copy").flatMap(rect), let clear = control("Clear Draft").flatMap(rect) else {
            throw Problem("Expanded copy, clear or chevron is missing or not visible.")
        }
        try need(copy.midX < row.midX && clear.midX < row.midX && chevron.midX > row.midX &&
                 copy.maxX <= clear.minX && clear.maxX < chevron.minX, "Expanded Copy and Clear are not on the left before the right chevron.")
        try need(try draftValue() == before, "Expansion changed the draft.")
        try click("Collapse Draft")
        try need(control("Expand Draft") != nil && control("Copy") == nil && control("Clear Draft") == nil, "Collapse did not restore the compact controls.")
        try need(try draftValue() == before, "Collapse changed the draft.")
        announce("AX compact draft height \(compact.height). Expanded positions: copy \(copy.midX), clear \(clear.midX), capsule center \(row.midX), chevron \(chevron.midX).")
    }

    func visibleButtons() -> [String] {
        capsuleNodes().filter { str($0, "AXRole") == "AXButton" && rect($0) != nil }
            .map { names($0).joined(separator: "|") }.sorted()
    }

    func empty() throws {
        try prepare("none")
        let before = visibleButtons()
        try need(try draftValue().isEmpty, "Empty message requires a blank draft.")
        try speaker("none")
        let status: String = try waitFor("No inline empty-input status was found.") {
            self.capsuleNodes().filter { str($0, "AXRole") == "AXStaticText" && rect($0) != nil }
                .flatMap { names($0) + [str($0, "AXValue")] }
                .first { value in
                    let lower = value.lowercased()
                    return ["no text", "nothing to read", "type a draft", "empty draft", "type or paste"].contains { lower.contains($0) }
                }
        }
        try noPermissionAction()
        try need(self.control("Stop Playback") == nil && visibleButtons() == before, "Empty read added a button or entered transport.")
        try need(try draftValue().isEmpty, "Empty read created draft text.")
        startedPlayback = false
        announce("Inline empty status: \(status). Visible controls and the empty draft stayed unchanged.")
    }

    func showFromHidden(reopen: Bool) throws {
        try focusDraft()
        try guardKeyboardTarget()
        try key(53)
        _ = try waitFor("Escape did not hide the idle capsule.") { self.capsule() == nil ? true : nil }
        let state = reopen ? "page-a" : "page-b"
        try prepare(state)
        if reopen {
            try guardCandidate()
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-a", config.candidate.path]
            try opener.run()
            opener.waitUntilExit()
            try need(opener.terminationStatus == 0, "Launch Services did not reopen the candidate.")
        } else {
            try key(49, flags: [.maskAlternate, .maskShift])
        }
        _ = try waitFor("The summon action did not show the standard capsule.") { self.control("Read Aloud") }
        try guardCandidate()
        try need(try draftValue() == draftText, "Showing the capsule changed the draft.")
        _ = try fixtureWindow(requireFront: false)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != browser.processIdentifier {
            browser.activate(options: [])
            try waitForBrowser()
        }
        try verifySelection(state)
        announce("\(reopen ? "Launch Services reopen" : "Option–Shift–Space summon") preserved candidate PID \(app.processIdentifier) and draft.")
        try speaker(state)
        try checkSnapshot(fixtureSelections[state]!.1)
        try stop()
    }

    func seek() -> Double? {
        guard let slider = control("Seek", role: "AXSlider") else { return nil }
        return (ax(slider, "AXValue") as? NSNumber)?.doubleValue
    }

    func advance(from before: Double) throws -> Double {
        try waitFor("The native playback timeline did not advance.", seconds: 25) {
            guard let after = self.seek(), after > before + 0.0002 else { return nil }
            return after
        }
    }

    func pause() throws -> Double {
        try click("Pause Playback")
        _ = try waitFor("Pause did not expose Resume Playback.") { self.control("Resume Playback") }
        sleepFor(0.18)
        guard let paused = seek() else { throw Problem("No timeline is available while paused.") }
        sleepFor(0.90)
        guard let held = seek() else { throw Problem("Paused timeline disappeared.") }
        try need(abs(paused - held) <= 0.0002, "Paused timeline kept advancing.")
        announce("Paused timeline held from \(paused) to \(held) over 0.90 seconds.")
        return held
    }

    func playingDraft(_ state: String) throws {
        try prepare(state)
        try speaker(state)
        try checkSnapshot(draftText)
    }

    func transport() throws {
        try playingDraft("none")
        guard let early = seek() else { throw Problem("Seek slider is unavailable.") }
        let advanced = try advance(from: early)
        announce("Playing timeline advanced from \(early) to \(advanced).")
        let held = try pause()
        try checkSnapshot(draftText)
        try click("Resume Playback")
        let resumed = try advance(from: held)
        announce("Resumed timeline advanced from \(held) to \(resumed).")
        try checkSnapshot(draftText)
        try stop()
    }

    func editUndo() throws {
        try playingDraft("none")
        _ = try advance(from: 0)
        let held = try pause()
        try click("Edit Draft")
        try focusDraft()
        try guardKeyboardTarget()
        try key(125, flags: command)
        try type(draftEdit, after: draftText)
        try click("Follow Along")
        try checkSnapshot(draftText)
        try click("Resume Playback")
        _ = try advance(from: held)
        try click("Stop Playback")
        _ = try waitFor("Stop did not restore the ordinary capsule.") { self.control("Read Aloud") }
        startedPlayback = false
        try need(try draftValue() == draftText + draftEdit, "Stop did not preserve the exact edited draft.")
        try focusDraft()
        try guardKeyboardTarget()
        try key(6, flags: command)
        try need(try draftValue() == draftText, "One Undo did not restore the exact original draft.")
        announce("Exact edit survived Stop; one native Command–Z restored the original draft.")
    }

    func guardKeyboardTarget() throws {
        try guardCandidate()
        let system = AXUIElementCreateSystemWide()
        let editor = try draft()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focus = element(ax(system, "AXFocusedUIElement"))
        try need(focus.map { CFEqual($0, editor) } == true ||
                 (front == app.processIdentifier &&
                  element(ax(appAX, "AXFocusedUIElement")).map { CFEqual($0, editor) } == true),
                 "Could not verify the disposable draft owns keyboard focus.")
    }

    func seed() throws {
        try need(try draftValue().isEmpty, "The draft is no longer empty.")
        if control("Collapse Draft") != nil { try click("Collapse Draft") }
        try focusDraft()
        try type(draftText, after: "")
    }

    func settleAfterFailure() {
        if startedPlayback && control("Stop Playback") != nil {
            try? click("Stop Playback")
            sleepFor(0.25)
        }
        startedPlayback = false
    }

    func clean() throws {
        settleAfterFailure()
        try need(capsule() != nil, "Could not verify a hidden capsule's fixture draft for cleanup.")
        let current = try draftValue()
        try need(ownedDrafts.contains(current), "Cleanup skipped because draft contents do not belong to this run.")
        guard !current.isEmpty else { return }
        try focusDraft()
        try guardKeyboardTarget()
        try need(try draftValue() == current, "Cleanup skipped because the fixture draft changed.")
        try key(0, flags: command)
        try guardKeyboardTarget()
        try key(51)
        try need(try draftValue().isEmpty, "Could not remove the disposable draft.")
    }

    func runCase(_ id: String, _ run: () throws -> Void) -> Result {
        facts = []
        do {
            try guardCandidate()
            try run()
            return Result(id: id, status: "completed", evidence: facts)
        } catch {
            settleAfterFailure()
            return Result(id: id, status: "failed", evidence: facts + [String(describing: error)])
        }
    }
}

func execute(_ config: Configuration) throws -> Bool {
    try need(!FileManager.default.fileExists(atPath: config.output.path), "Select a new report directory.")
    try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: false)
    let file = config.output.appendingPathComponent("readings.json")
    let fixtureHash = (try? sha(config.fixture)) ?? ""
    var report = Report(candidate: config.candidate.path, sha256: config.expectedSHA,
                        fixtureSHA256: fixtureHash, target: config.target, mode: config.mode,
                        started: ISO8601DateFormatter().string(from: Date()))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    func save(_ result: Result) throws {
        report.results.append(result)
        try encoder.encode(report).write(to: file, options: .atomic)
        print("\(result.status) \(result.id): \(result.evidence.joined(separator: " | "))")
        fflush(stdout)
    }

    let expectedFixtureHash = "ce7371c6e462d1213c17cee0d0d49d59cff3727b4e5a0df854cff7aa26f3fed1"
    let isSpotCheck = ["chrome", "firefox"].contains(config.target)
    let wanted: Set<String>
    if config.mode == "unavailable" {
        wanted = ["empty", "unavailable", "transport", "edit-undo"]
    } else if isSpotCheck {
        wanted = ["fresh-page", "textarea"]
    } else {
        wanted = Set(caseIDs).subtracting(["unavailable"])
    }
    let journey: Journey
    do {
        try need(fixtureHash == expectedFixtureHash, "Fixture bytes differ from the frozen fixture.")
        journey = try Journey(config)
        report.candidatePID = journey.app.processIdentifier
        report.browserPID = journey.browser.processIdentifier
        report.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        report.browserVersion = journey.browser.bundleURL.flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        try save(Result(id: "preflight", status: "completed", evidence: [
            "Verified exact executable hash, single running candidate, browser PID, exact fixture URL, supported input access and empty idle draft."
        ]))
    } catch {
        try save(Result(id: "preflight", status: "blocked", evidence: [String(describing: error)]))
        for id in caseIDs where wanted.contains(id) {
            try save(Result(id: id, status: "blocked", evidence: ["Live preflight was blocked."]))
        }
        return false
    }

    let runs: [String: () throws -> Void] = [
        "layout": journey.layout, "empty": journey.empty,
        "fresh-page": { try journey.selectionRead("page-a") },
        "reselect": { try journey.selectionRead("page-b") },
        "textarea": { try journey.selectionRead("textarea") },
        "deselection": { try journey.playingDraft("none"); try journey.stop() },
        "wake": { try journey.showFromHidden(reopen: false) },
        "reopen": { try journey.showFromHidden(reopen: true) },
        "unavailable": { try journey.playingDraft("page-a"); try journey.stop() },
        "transport": journey.transport, "edit-undo": journey.editUndo
    ]
    var seeded = false
    for id in caseIDs where wanted.contains(id) {
        if id != "layout" && id != "empty" && !seeded {
            do {
                try journey.seed()
                seeded = true
            } catch {
                try save(Result(id: "seed", status: "blocked", evidence: [String(describing: error)]))
                for skipped in caseIDs.drop(while: { $0 != id }) where wanted.contains(skipped) {
                    try save(Result(id: skipped, status: "blocked", evidence: ["Disposable draft setup was blocked."]))
                }
                break
            }
        }
        guard let run = runs[id] else { throw Problem("Runner has no implementation for \(id).") }
        try save(journey.runCase(id, run))
    }
    do {
        try journey.clean()
        try journey.guardCandidate()
        try save(Result(id: "cleanup", status: "completed", evidence: ["Only the fixture draft was cleared; the exact candidate remained running."]))
    } catch {
        try save(Result(id: "cleanup", status: "blocked", evidence: [String(describing: error)]))
    }
    return report.results.allSatisfy { $0.status == "completed" }
}

do {
    let configuration = try Configuration(Array(CommandLine.arguments.dropFirst()))
    exit(try execute(configuration) ? 0 : 1)
} catch {
    fputs("\(error)\n", stderr)
    exit(2)
}
