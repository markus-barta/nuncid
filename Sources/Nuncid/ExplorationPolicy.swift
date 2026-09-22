import AppKit

/// Upgrading never starts a background scan. Enabled shortcuts are preserved;
/// the legacy Off mode migrates to a disabled activation shortcut.
struct ExplorationPreferences: Equatable {
    var hoverMilliseconds = 100
    var parallelLookups = 3
    var refreshOnSourceWindowChanges = false

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(
            hoverMilliseconds: defaults.object(forKey: "exploration.hoverMilliseconds") == nil ? 100 : min(500, max(0, defaults.integer(forKey: "exploration.hoverMilliseconds"))),
            parallelLookups: defaults.object(forKey: "exploration.parallelLookups") == nil ? 3 : min(5, max(1, defaults.integer(forKey: "exploration.parallelLookups"))),
            refreshOnSourceWindowChanges: defaults.bool(forKey: "exploration.refreshOnSourceWindowChanges")
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
        defaults.set(refreshOnSourceWindowChanges, forKey: "exploration.refreshOnSourceWindowChanges")
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

/// A stable snapshot of one display's AppKit and Quartz coordinate spaces.
/// Keeping this with each tile prevents a later pointer move from changing
/// which display is captured or where recognized text is anchored.
struct ExplorationDisplay: Equatable {
    let id: UInt32
    let frame: CGRect
    let content: CGRect
    let quartzBounds: CGRect

    func capturePlan(for bounds: CGRect) -> CapturePlan? {
        let bounded = bounds.intersection(content)
        guard bounded.width > 20, bounded.height > 20 else { return nil }
        let quartz = CGRect(x: quartzBounds.minX + bounded.minX - frame.minX,
                            y: quartzBounds.minY + frame.maxY - bounded.maxY,
                            width: bounded.width, height: bounded.height)
        return CapturePlan(rect: quartz, displayBounds: quartzBounds, screenFrame: frame)
    }
}

struct ExplorationTile: Equatable {
    let display: ExplorationDisplay
    let bounds: CGRect
}

enum ExplorationPolicy {
    static let settleDuration: TimeInterval = 0.3
    static let maximumCandidates = 512

    static func contentFrame(screen: CGRect, visible: CGRect, menuHeight: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: screen.minY, width: screen.width,
               height: max(0, screen.height - max(0, menuHeight))).intersection(visible)
    }

    static func orderedDisplays(_ displays: [ExplorationDisplay], around point: CGPoint) -> [ExplorationDisplay] {
        var unique: [ExplorationDisplay] = []
        // Mirrored displays share a frame and should only be scanned once.
        for display in displays.sorted(by: { $0.id < $1.id }) where !unique.contains(where: { $0.frame == display.frame }) {
            unique.append(display)
        }
        return unique.sorted {
            let lhsContains = $0.frame.contains(point), rhsContains = $1.frame.contains(point)
            if lhsContains != rhsContains { return lhsContains }
            let lhs = distance($0.frame, to: point), rhs = distance($1.frame, to: point)
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    /// Finish one display before moving to the next; never interleave their
    /// tiles or launch a separate OCR task for every attached screen.
    static func scanTiles(on displays: [ExplorationDisplay], around point: CGPoint) -> [ExplorationTile] {
        orderedDisplays(displays, around: point).flatMap { display in
            tiles(in: display.content, around: point).map { ExplorationTile(display: display, bounds: $0) }
        }
    }

    static func reprioritize(_ tiles: [ExplorationTile], around point: CGPoint) -> [ExplorationTile] {
        orderedDisplays(tiles.map(\.display), around: point).flatMap { display in
            tiles.filter { $0.display.id == display.id }.sorted {
                let lhs = distance($0.bounds, to: point), rhs = distance($1.bounds, to: point)
                if lhs != rhs { return lhs < rhs }
                if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY > $1.bounds.minY }
                return $0.bounds.minX < $1.bounds.minX
            }
        }
    }

    static func localMarker(_ bounds: CGRect, on frame: CGRect) -> CGRect? {
        let clipped = bounds.intersection(frame)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped.offsetBy(dx: -frame.minX, dy: -frame.minY)
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

    /// Pull requests and workflow runs reread the owning window, capped, so a
    /// GitHub URL above a later mention shares one capture. Other references
    /// keep the narrow crop used to recover a flag cut off the same line.
    static func contextRead(around anchor: CGRect, category: ScreenReferenceCategory, owner: CGRect?, content: CGRect) -> CGRect {
        if category == .pullRequest || category == .workflowRun, let owner {
            let window = owner.intersection(content)
            if window.width > 20, window.height > 20 {
                if window.height <= 1_600 { return window }
                return CGRect(x: window.minX, y: anchor.midY - 800, width: window.width, height: 1_600).intersection(window)
            }
        }
        return CGRect(x: anchor.midX - 500, y: anchor.midY - 120, width: 1_000, height: 240).intersection(content)
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
