import AppKit
import CoreGraphics

struct ScreenContextWindow: Equatable {
    let id: Int
    let bounds: CGRect
}

enum ScreenContextGeometry {
    /// Front-to-back ownership. A line crossing a window/occlusion boundary is
    /// not safe context; discard it rather than borrowing text from both apps.
    static func owner(of bounds: CGRect, windows: [ScreenContextWindow]) -> Int? {
        guard !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite else { return nil }
        guard let first = windows.first(where: { $0.bounds.intersects(bounds) }), first.bounds.contains(bounds) else { return nil }
        return first.id
    }

    static func isCompleteIdentifier(_ bounds: CGRect, in capture: CGRect) -> Bool {
        guard capture.width > 6, capture.height > 6 else { return false }
        return capture.insetBy(dx: 3, dy: 3).contains(bounds)
    }

    @MainActor static func windows(for capture: CapturePlan) -> [ScreenContextWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = window[kCGWindowNumber as String] as? Int,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return ScreenContextWindow(id: id, bounds: capture.appKitRect(forQuartz: rect))
        }
    }
}
