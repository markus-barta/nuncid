import AppKit

/// Upgrading never starts a background scan. Enabled shortcuts are preserved;
/// the legacy Off mode migrates to a disabled activation shortcut.
struct ExplorationPreferences: Equatable {
    var hoverMilliseconds = 100
    var parallelLookups = 3

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(
            hoverMilliseconds: defaults.object(forKey: "exploration.hoverMilliseconds") == nil ? 100 : min(500, max(0, defaults.integer(forKey: "exploration.hoverMilliseconds"))),
            parallelLookups: defaults.object(forKey: "exploration.parallelLookups") == nil ? 3 : min(5, max(1, defaults.integer(forKey: "exploration.parallelLookups")))
        )
    }

    static func migrateShortcutIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "exploration.shortcutsMigrated") else { return }
        let raw = defaults.string(forKey: "activation.mode") ?? defaults.string(forKey: "triggerMode")
        if ActivationPreferences.migratedMode(from: raw) == .off {
            NuncidPreferences.save(nil, key: "inspectHotKey", defaults: defaults)
        }
        defaults.set(true, forKey: "exploration.shortcutsMigrated")
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(min(500, max(0, hoverMilliseconds)), forKey: "exploration.hoverMilliseconds")
        defaults.set(min(5, max(1, parallelLookups)), forKey: "exploration.parallelLookups")
    }
}

enum ExplorationOutcome: Equatable {
    case queued, resolving, matched, missed

    func isNavigable(includeMisses: Bool) -> Bool { self != .missed || includeMisses }
    var markerState: MarkerVisualState {
        switch self {
        case .queued, .resolving: return .unchecked
        case .matched: return .matched
        case .missed: return .missed
        }
    }
}

enum PopupScrollPresentationPolicy {
    static let settlingDelay: TimeInterval = 0.35
    static func opacity(pointerInside: Bool, recentlyScrolling: Bool, reduceTransparency: Bool) -> CGFloat {
        !pointerInside && recentlyScrolling && !reduceTransparency ? 0.5 : 1
    }
}

struct ExplorationHover {
    private(set) var candidate: String?
    private var since = Date.distantPast
    private var delivered = false

    mutating func update(candidate: String?, now: Date, delay: TimeInterval) -> String? {
        if candidate != self.candidate {
            self.candidate = candidate
            since = now
            delivered = false
        }
        guard let candidate, !delivered, now.timeIntervalSince(since) >= max(0, delay) else { return nil }
        delivered = true
        return candidate
    }
}

enum ExplorationPolicy {
    static let settleDuration: TimeInterval = 0.3
    static let maximumCandidates = 512

    static func contentFrame(screen: CGRect, visible: CGRect, menuHeight: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: screen.minY, width: screen.width,
               height: max(0, screen.height - max(0, menuHeight))).intersection(visible)
    }

    /// Overlapping fixed-size tiles preserve small-text recognition accuracy as
    /// discovery expands. The invoked tile is first, then increasing distance.
    static func tiles(in frame: CGRect, around point: CGPoint) -> [CGRect] {
        guard frame.width > 20, frame.height > 20 else { return [] }
        let size = CGSize(width: min(620, frame.width), height: min(300, frame.height))
        let first = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height).intersection(frame)
        var tiles: [CGRect] = []
        var y = frame.minY
        while y < frame.maxY {
            var x = frame.minX
            while x < frame.maxX {
                let tile = CGRect(x: min(x, frame.maxX - size.width), y: min(y, frame.maxY - size.height), width: size.width, height: size.height)
                if !tiles.contains(tile), tile != first { tiles.append(tile) }
                x += max(1, size.width - 80)
            }
            y += max(1, size.height - 60)
        }
        tiles.sort {
            let lhs = distance($0, to: point), rhs = distance($1, to: point)
            if lhs != rhs { return lhs < rhs }
            if $0.minY != $1.minY { return $0.minY > $1.minY }
            return $0.minX < $1.minX
        }
        return (first.width > 20 && first.height > 20 ? [first] : []) + tiles
    }

    static func sameOccurrence(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = lhs.intersection(rhs)
        let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smaller > 0 && !overlap.isNull && overlap.width * overlap.height / smaller > 0.75
    }

    static func distance(_ rect: CGRect, to point: CGPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }

    static func dispatch(pending: [String], running: Set<String>, promoted: String?, limit: Int) -> [String] {
        var seen = running
        var ready = pending.filter { seen.insert($0).inserted }
        if let promoted, let index = ready.firstIndex(of: promoted) { ready.insert(ready.remove(at: index), at: 0) }
        return Array(ready.prefix(max(0, min(5, max(1, limit)) - running.count)))
    }

    static func next(in ids: [String], selected: String?, direction: Int, eligible: Set<String>? = nil) -> String? {
        guard !ids.isEmpty else { return nil }
        let step = direction < 0 ? -1 : 1
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? (step < 0 ? 0 : -1)
        for offset in 1...ids.count {
            let candidate = ids[(index + step * offset + ids.count * 2) % ids.count]
            if eligible?.contains(candidate) != false { return candidate }
        }
        return nil
    }
}

/// Shared by OCR exploration and manual entry. Cancelled waiters never acquire
/// a slot. A slot is held until the child process has actually terminated.
actor TrackerReadBudget {
    static let shared = TrackerReadBudget()
    private var active = 0
    private var limit = 3

    func configure(_ value: Int) { limit = min(5, max(1, value)) }
    func acquire() async -> Bool {
        while active >= limit {
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        }
        guard !Task.isCancelled else { return false }
        active += 1
        return true
    }
    func release() { active -= 1 }
}
