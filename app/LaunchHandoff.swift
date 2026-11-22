import AppKit
import CoreFoundation

final class LaunchHandoff {
    enum Result {
        case primary, forwarded, unavailable
    }

    private let name = ((Bundle.main.bundleIdentifier ?? "local.ahampo.capsule") + ".reopen") as CFString
    private static let showMessage: Int32 = 1
    private var localPort: CFMessagePort?
    var showCapsule: (() -> Void)?

    deinit {
        if let localPort { CFMessagePortInvalidate(localPort) }
    }

    func claim() -> Result {
        // Older builds predate the message port. Keep their live session and ask
        // Launch Services to reopen that copy until the user quits it.
        if let previous = legacyInstance() {
            guard let url = previous.bundleURL, NSWorkspace.shared.open(url) else { return .unavailable }
            return .forwarded
        }

        var context = CFMessagePortContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        for attempt in 0..<3 {
            if let port = CFMessagePortCreateLocal(nil, name, { _, message, _, context in
                guard message == LaunchHandoff.showMessage, let context else { return nil }
                Unmanaged<LaunchHandoff>.fromOpaque(context).takeUnretainedValue().showCapsule?()
                return Unmanaged.passRetained(Data() as CFData)
            }, &context, nil) {
                guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
                    CFMessagePortInvalidate(port)
                    return .unavailable
                }
                localPort = port
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                return .primary
            }

            if let primary = CFMessagePortCreateRemote(nil, name) {
                let result = CFMessagePortSendRequest(primary, Self.showMessage, nil, 0.25, 0, nil, nil)
                if result == kCFMessagePortSuccess { return .forwarded }
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return .unavailable
    }

    private func legacyInstance() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first { app in
            guard app.processIdentifier != current, !app.isTerminated, let url = app.bundleURL else { return false }
            return Bundle(url: url)?.object(forInfoDictionaryKey: "AHAMPOLaunchHandoff") as? Bool != true
        }
    }
}
