import Foundation

/// User intent is independent of transient capture availability and pin state.
/// Intentionally starts OFF on launch; sleep never changes the user's intent.
struct DetectionMode: Equatable {
    private(set) var enabled = false
    mutating func toggle() { enabled.toggle() }
    mutating func stop() { enabled = false }
    func keepsWindow(pinned: Bool) -> Bool { enabled || pinned }
}

struct InspectionZoom: Equatable {
    static let key = "inspectionZoomPercent"
    static let minimum = 30
    static let maximum = 300
    static let step = 10
    static let headerHeight: CGFloat = 58
    static let minimumWindow = CGSize(width: 300, height: 130)
    let percent: Int
    var scale: CGFloat { CGFloat(percent) / 100 }

    init(_ percent: Int = 100) { self.percent = min(Self.maximum, max(Self.minimum, percent)) }
    func changed(by steps: Int) -> Self { Self(percent + steps * Self.step) }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: key) != nil else { return Self() }
        return Self(defaults.integer(forKey: key))
    }
    func persist(defaults: UserDefaults = .standard) { defaults.set(percent, forKey: Self.key) }

    /// Chrome is kept at native size. Everything below it, including spacing,
    /// icons and hit targets, is magnified together without reflowing text.
    func requestedSize(baseline: CGSize) -> CGSize {
        CGSize(width: max(Self.minimumWindow.width, baseline.width * scale),
               height: max(Self.minimumWindow.height, Self.headerHeight + max(0, baseline.height - Self.headerHeight) * scale))
    }
    static func bounded(_ size: CGSize, visible: CGRect) -> CGSize {
        CGSize(width: min(max(minimumWindow.width, size.width), max(1, visible.width - 16)),
               height: min(max(minimumWindow.height, size.height), max(1, visible.height - 16)))
    }
    func baseline(afterResize size: CGSize) -> CGSize {
        CGSize(width: size.width / scale, height: Self.headerHeight + max(0, size.height - Self.headerHeight) / scale)
    }
}
