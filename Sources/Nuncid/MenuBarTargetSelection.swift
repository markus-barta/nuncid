import Foundation

/// No capture occurs here. Select one initial content target before starting
/// detection; consuming it prevents duplicate dwell/click starts. Persistent
/// detection disables expiry and keeps waiting through permission pauses.
struct MenuBarTargetSelection {
    enum Decision: Equatable {
        case waiting
        case scan(CGPoint)
        case cancelled
    }
    static func isContent(position: CGPoint, screenFrame: CGRect, menuHeight: CGFloat) -> Bool {
        screenFrame.contains(position) && position.y < screenFrame.maxY - menuHeight
    }

    static let timeout: TimeInterval = 15
    static let settleDuration: TimeInterval = 0.35
    private let startedAt: Date
    private let expires: Bool
    private var anchor: CGPoint?
    private var stableSince: Date?
    private var finished = false

    init(now: Date, expires: Bool = true) { startedAt = now; self.expires = expires }

    mutating func update(position: CGPoint, eligible: Bool, now: Date,
                         clicked: Bool = false, permissionGranted: Bool = true) -> Decision {
        guard !finished else { return .cancelled }
        if !expires, !permissionGranted {
            anchor = nil; stableSince = nil
            return .waiting
        }
        guard permissionGranted, !expires || now.timeIntervalSince(startedAt) < Self.timeout else {
            finished = true
            return .cancelled
        }
        guard eligible else {
            anchor = nil
            stableSince = nil
            return .waiting
        }
        if clicked {
            finished = true
            return .scan(position)
        }
        if anchor.map({ hypot(position.x - $0.x, position.y - $0.y) > 4 }) ?? true {
            anchor = position
            stableSince = now
        }
        guard let stableSince, now.timeIntervalSince(stableSince) >= Self.settleDuration else { return .waiting }
        finished = true
        return .scan(position)
    }
}
