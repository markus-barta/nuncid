import Carbon
import Foundation

struct Tracker: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init?(rawValue: String) {
        guard rawValue.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z"#, options: .regularExpression) != nil else { return nil }
        self.rawValue = rawValue
    }
    static let ppm = Tracker(rawValue: "ppm")!
    static let pma = Tracker(rawValue: "pma")!
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let tracker = Tracker(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid instance name")
        }
        self = tracker
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct HotKeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32

    static let command = HotKeyModifiers(rawValue: 1 << 0)
    static let option = HotKeyModifiers(rawValue: 1 << 1)
    static let control = HotKeyModifiers(rawValue: 1 << 2)
    static let shift = HotKeyModifiers(rawValue: 1 << 3)

    var label: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

struct HotKey: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: HotKeyModifiers
    let keyLabel: String

    static let inspect = HotKey(keyCode: 49, modifiers: [.option], keyLabel: "Space")
    static let pin = HotKey(keyCode: 49, modifiers: [.option, .shift], keyLabel: "Space")

    var label: String { modifiers.label + keyLabel }

    private static let functionKeyLabels: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
    ]

    static func functionKeyLabel(for keyCode: UInt32) -> String? {
        functionKeyLabels[keyCode]
    }

    var isSafeGlobalShortcut: Bool {
        return Self.functionKeyLabel(for: keyCode) != nil || !modifiers.intersection([.command, .option, .control]).isEmpty
    }
}

enum ShortcutCaptureDecision: Equatable {
    case cancel
    case clear
    case rejectUnsafe
    case rejectDuplicate
    case accept(HotKey)
}

enum ShortcutCapturePolicy {
    static func decision(for candidate: HotKey, forbiddenHotKey: HotKey?) -> ShortcutCaptureDecision {
        if candidate.keyCode == UInt32(kVK_Escape) { return .cancel }
        if candidate.keyCode == UInt32(kVK_Delete) || candidate.keyCode == UInt32(kVK_ForwardDelete) { return .clear }
        guard candidate.isSafeGlobalShortcut else { return .rejectUnsafe }
        guard candidate != forbiddenHotKey else { return .rejectDuplicate }
        return .accept(candidate)
    }
}

struct NuncidPreferences: Equatable {
    var inspectHotKey: HotKey?
    var pinHotKey: HotKey?

    static func load(defaults: UserDefaults = .standard) -> NuncidPreferences {
        return NuncidPreferences(
            inspectHotKey: decodeHotKey(key: "inspectHotKey", fallback: .inspect, defaults: defaults),
            pinHotKey: decodeHotKey(key: "pinHotKey", fallback: .pin, defaults: defaults)
        )
    }

    static func save(_ hotKey: HotKey?, key: String, defaults: UserDefaults = .standard) {
        if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set(Data(), forKey: key)
        }
    }

    static func shortcutsConflict(inspect: HotKey?, pin: HotKey?) -> Bool {
        guard let inspect, let pin else { return false }
        return inspect == pin
    }

    private static func decodeHotKey(key: String, fallback: HotKey, defaults: UserDefaults) -> HotKey? {
        guard defaults.object(forKey: key) != nil else { return fallback }
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(HotKey.self, from: data)
    }
}

struct TicketLine: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let key: String
    let state: String
    let title: String
    let source: String
    let metadata: String
    let detail: String
    let destination: String?

    init(key: String, state: String, title: String, source: String, metadata: String = "", detail: String = "", destination: String? = nil, identity: String? = nil) {
        self.id = identity ?? "\(source):\(key)"
        self.key = key
        self.state = state
        self.title = title
        self.source = source
        self.metadata = metadata
        self.detail = detail
        self.destination = destination
    }

    var destinationURL: URL? {
        if let destination, let url = URL(string: destination) { return url }
        switch source.lowercased() {
        case "gh":
            let repo = metadata.split(separator: "·", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let repo, !repo.isEmpty, key.hasPrefix("#") else { return nil }
            return URL(string: "https://github.com/\(repo)/pull/\(key.dropFirst())")
        default:
            guard let connection = TrackerDirectory.shared.connections.first(where: { $0.id == source }),
                  let destination = connection.destination(key: key) else { return nil }
            return URL(string: destination)
        }
    }
}

enum HoverResultPolicy {
    static let maximumResults = 12

    static func visible(from attempts: [TicketLine?], limit: Int = maximumResults) -> [TicketLine] {
        var seen = Set<String>()
        return attempts.compactMap { $0 }
            .filter { !$0.key.isEmpty && seen.insert($0.id).inserted }
            .prefix(max(0, limit))
            .map { $0 }
    }
}

struct ResolutionContext: Equatable, Sendable {
    var lastSeenTracker: Tracker
    var ppmProject: String
    var pmaProject: String
    var additionalProjects: [String: String] = [:]

    static func load(defaults: UserDefaults = .standard) -> ResolutionContext {
        ResolutionContext(
            lastSeenTracker: Tracker(rawValue: defaults.string(forKey: "lastSeenTracker") ?? "ppm") ?? .ppm,
            ppmProject: defaults.string(forKey: "lastPPMProject") ?? "PAI",
            pmaProject: defaults.string(forKey: "lastPMAProject") ?? "START",
            additionalProjects: defaults.dictionary(forKey: "lastAdditionalProjects") as? [String: String] ?? [:]
        )
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "lastSeenTracker")
        defaults.removeObject(forKey: "lastPPMProject")
        defaults.removeObject(forKey: "lastPMAProject")
        defaults.removeObject(forKey: "lastAdditionalProjects")
    }

    func project(for tracker: Tracker) -> String {
        if tracker == .ppm { return ppmProject }
        if tracker == .pma { return pmaProject }
        return additionalProjects[tracker.rawValue] ?? TrackerDirectory.shared.projects.first(where: { $0.tracker == tracker })?.key ?? ppmProject
    }

    func rememberedProject(for tracker: Tracker) -> String? {
        if tracker == .ppm { return ppmProject }
        if tracker == .pma { return pmaProject }
        return additionalProjects[tracker.rawValue]
    }

    mutating func saw(project: String, on tracker: Tracker, defaults: UserDefaults = .standard) {
        lastSeenTracker = tracker
        if tracker == .ppm { ppmProject = project } else if tracker == .pma { pmaProject = project }
        else { additionalProjects[tracker.rawValue] = project }
        defaults.set(tracker.rawValue, forKey: "lastSeenTracker")
        defaults.set(ppmProject, forKey: "lastPPMProject")
        defaults.set(pmaProject, forKey: "lastPMAProject")
        defaults.set(additionalProjects, forKey: "lastAdditionalProjects")
    }
}

struct PinnedTicketContext: Equatable, Sendable {
    var project: String
    var number: Int?

    static func load(defaults: UserDefaults = .standard, fallback: ResolutionContext = .load()) -> PinnedTicketContext {
        PinnedTicketContext(
            project: defaults.string(forKey: "pinnedProject") ?? fallback.project(for: fallback.lastSeenTracker),
            number: defaults.object(forKey: "pinnedNumber") as? Int
        )
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(project, forKey: "pinnedProject")
        if let number { defaults.set(number, forKey: "pinnedNumber") }
        else { defaults.removeObject(forKey: "pinnedNumber") }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "pinnedProject")
        defaults.removeObject(forKey: "pinnedNumber")
    }
}

enum CandidateSpec: Hashable, Sendable {
    case issue(tracker: Tracker, key: String)
    case pullRequest(number: Int, repo: String)
    case workflowRun(id: Int, repo: String)
    var cacheKey: String {
        switch self {
        case let .issue(tracker, key): return "issue:\(tracker.rawValue):\(key)"
        case let .pullRequest(number, repo): return "pr:\(repo):\(number)"
        case let .workflowRun(id, repo): return "run:\(repo):\(id)"
        }
    }
}

enum PinnedInputEvent {
    case digits(String)
    case letters(String)
    case backspace
    case submit
    case escape
    case paste(String)
}

enum PanelInteractionState { case hidden, temporary, pinnedInactive, pinnedActive }
enum PinCommandAction: Equatable { case openPinned, pinTemporary, focusPinned, closePinned }

enum PinCommandPolicy {
    static func action(for state: PanelInteractionState) -> PinCommandAction {
        switch state {
        case .hidden: return .openPinned
        case .temporary: return .pinTemporary
        case .pinnedInactive: return .focusPinned
        case .pinnedActive: return .closePinned
        }
    }

    static func clearsManualInspection(for action: PinCommandAction) -> Bool {
        action == .openPinned || action == .pinTemporary
    }
}

enum CircularNavigation {
    static func advancedIndex(current: Int, direction: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + direction % count + count) % count
    }
}

enum PanelPlacement {
    static func clamped(origin: CGPoint, size: CGSize, visibleFrame: CGRect, inset: CGFloat = 8) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visibleFrame.minX + inset), visibleFrame.maxX - size.width - inset),
            y: min(max(origin.y, visibleFrame.minY + inset), visibleFrame.maxY - size.height - inset)
        )
    }
}

struct PinnedEditState: Equatable {
    enum Channel { case number, project, none }

    var numberBuffer: String?
    var projectQuery = ""
    var projectBeforeQuery: String?
    var hasInput: Bool { numberBuffer != nil || !projectQuery.isEmpty }

    mutating func appendDigits(_ value: String) {
        projectQuery = ""; projectBeforeQuery = nil
        numberBuffer = (numberBuffer ?? "") + value
    }

    mutating func appendLetters(_ value: String, currentProject: String) {
        numberBuffer = nil
        if projectQuery.isEmpty { projectBeforeQuery = currentProject }
        projectQuery += value
    }

    mutating func backspace() -> Channel {
        if !projectQuery.isEmpty {
            projectQuery.removeLast(); return .project
        }
        if var value = numberBuffer, !value.isEmpty {
            value.removeLast(); numberBuffer = value; return .number
        }
        return .none
    }

    mutating func clear() { numberBuffer = nil; projectQuery = ""; projectBeforeQuery = nil }
}

struct ProjectDescriptor: Hashable, Identifiable, Codable, Sendable {
    let key: String
    let name: String
    let aliases: [String]
    let tracker: Tracker
    var id: String { "\(tracker.rawValue):\(key)" }

    static var known: [ProjectDescriptor] { TrackerDirectory.shared.projects }
    // Names/aliases are presentation hints only; they never authorize a route.
    static let presentationHints: [ProjectDescriptor] = [
        .init(key: "NUNCID", name: "Nuncid", aliases: ["nuncid", "nun sid", "identify now", "ticket lens"], tracker: .ppm),
        // Retain OCR/history resolution for old ticket keys; hide from selection.
        .init(key: "GLINT", name: "Glint (historical)", aliases: ["glint"], tracker: .ppm),
        .init(key: "HAUSV", name: "Hausverwaltung", aliases: ["hausv", "hausverwaltung"], tracker: .ppm),
        .init(key: "INSPR", name: "Inspr", aliases: ["inspr", "inspire"], tracker: .ppm),
        .init(key: "JANUS", name: "Janus", aliases: ["janus"], tracker: .ppm),
        .init(key: "PAI", name: "Paimos", aliases: ["pai", "paimos", "ppm"], tracker: .ppm),
        .init(key: "PHAROS", name: "Pharos", aliases: ["pharos", "pharos crm"], tracker: .ppm),
        .init(key: "START", name: "Start AGM", aliases: ["start", "start agm"], tracker: .pma),
    ]
    static var selectable: [ProjectDescriptor] { known.filter { $0.key != "GLINT" }.map { project in
        project.key == "NUNCID"
            ? ProjectDescriptor(key: project.key, name: project.name, aliases: project.aliases + ["glint"], tracker: project.tracker)
            : project
    } }
}

enum ProjectMatcher {
    static func cycle(_ direction: Int, projects: [ProjectDescriptor], current: String, tracker: Tracker?) -> ProjectDescriptor? {
        guard !projects.isEmpty else { return nil }
        let index = projects.firstIndex { $0.key == current && $0.tracker == tracker }
            ?? projects.firstIndex { $0.key == current } ?? 0
        let step = direction < 0 ? -1 : 1
        return projects[(index + step + projects.count) % projects.count]
    }

    static func bestMatch(for rawQuery: String, projects: [ProjectDescriptor] = ProjectDescriptor.selectable, current: String? = nil) -> ProjectDescriptor? {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return projects.first(where: { $0.key == current }) ?? projects.first }
        return projects.max { lhs, rhs in
            score(lhs, query: query, current: current) < score(rhs, query: query, current: current)
        }
    }

    private static func score(_ project: ProjectDescriptor, query: String, current: String?) -> Int {
        let terms = ([project.key, project.name] + project.aliases).map(normalize)
        var best = Int.min
        for term in terms {
            let distance = damerauLevenshtein(query, term)
            var value = max(0, 1_000 - distance * 85 - abs(term.count - query.count) * 8)
            if term == query { value += 10_000 }
            else if term.hasPrefix(query) { value += 5_000 - (term.count - query.count) * 10 }
            else if isSubsequence(query, of: term) { value += 2_000 }
            best = max(best, value)
        }
        if project.key == current { best += 5 }
        return best
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter(\.isLetter)
            .lowercased()
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remainder = needle[...]
        for character in haystack where !remainder.isEmpty && character == remainder.first { remainder.removeFirst() }
        return remainder.isEmpty
    }

    static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let substitution = a[i - 1] == b[j - 1] ? 0 : 1
                matrix[i][j] = min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + substitution)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    matrix[i][j] = min(matrix[i][j], matrix[i - 2][j - 2] + 1)
                }
            }
        }
        return matrix[a.count][b.count]
    }
}
