import AppKit

enum BrandIcon: Int, CaseIterable {
    case automatic, rosa, azul

    static let labels = ["Automatic", "Rosa", "Azul"]

    static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15))
            circle.lineWidth = 1
            circle.stroke()

            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 3.9, y: 12))
            for point in [NSPoint(x: 6.2, y: 6), NSPoint(x: 8.5, y: 12),
                          NSPoint(x: 10, y: 8.2), NSPoint(x: 11.5, y: 10.7),
                          NSPoint(x: 13, y: 8.2), NSPoint(x: 14.1, y: 12)] {
                wave.line(to: point)
            }
            wave.lineWidth = 1.2
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Amapoani"
        return image
    }()

    func resource(dark: Bool) -> String {
        let rose = self == .rosa || (self == .automatic && dark)
        return (rose ? "Rosa" : "Azul") + (dark ? "-dark" : "-light")
    }

    static func apply(appearance: NSAppearance) {
        let choice = Self(rawValue: UserDefaults.standard.integer(forKey: Preference.iconStyle)) ?? .automatic
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = choice.resource(dark: dark)
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"),
           let appIcon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = appIcon
        }
    }
}
