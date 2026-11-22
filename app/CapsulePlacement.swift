import CoreGraphics

enum CapsulePosition: Int, CaseIterable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    func anchor(in screen: CGRect, width: CGFloat) -> CGPoint {
        let inset: CGFloat = 24
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = screen.minX + inset
        case .topCenter, .bottomCenter: x = screen.midX - width / 2
        case .topRight, .bottomRight: x = screen.maxX - inset - width
        }
        let isTop = rawValue <= Self.topRight.rawValue
        let y = isTop ? screen.maxY - inset - CapsulePlacement.rowHeight : screen.minY + inset
        return CGPoint(x: x, y: y)
    }
}

enum CapsuleExpansion: Int {
    case upward, downward
}

struct CapsulePlacement {
    static let rowHeight: CGFloat = 64
    static let expandedHeight: CGFloat = 220

    let anchor: CGPoint
    let expansion: CapsuleExpansion
    let frame: CGRect

    init(anchor: CGPoint, width: CGFloat, height: CGFloat, expandedHeight: CGFloat,
         inside usable: CGRect, preferred: CapsuleExpansion) {
        let anchor = CGPoint(x: min(max(anchor.x, usable.minX), max(usable.minX, usable.maxX - width)),
                             y: min(max(anchor.y, usable.minY), max(usable.minY, usable.maxY - Self.rowHeight)))
        self.anchor = anchor
        let roomAbove = usable.maxY - anchor.y - Self.rowHeight
        let roomBelow = anchor.y - usable.minY
        let needed = expandedHeight - Self.rowHeight
        let preferredRoom = preferred == .upward ? roomAbove : roomBelow
        let opposite: CapsuleExpansion = preferred == .upward ? .downward : .upward
        let oppositeRoom = preferred == .upward ? roomBelow : roomAbove
        if preferredRoom >= needed || (oppositeRoom < needed && preferredRoom >= oppositeRoom) {
            expansion = preferred
        } else {
            expansion = opposite
        }
        let desiredY = expansion == .downward ? anchor.y + Self.rowHeight - height : anchor.y
        let y = min(max(desiredY, usable.minY), max(usable.minY, usable.maxY - height))
        frame = CGRect(x: anchor.x, y: y, width: width, height: height)
    }
}
