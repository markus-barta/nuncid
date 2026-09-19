import Foundation

struct TrackerConnection: Codable, Equatable, Identifiable, Sendable {
    let tracker: Tracker
    /// Optional browser destination. Authentication and API routing belong to paimos.
    let webURL: String
    var id: String { tracker.rawValue }

    static let defaults: [TrackerConnection] = [
        .init(tracker: .ppm, webURL: "https://pm.barta.cm"),
        .init(tracker: .pma, webURL: "https://paimos.agm.ng")
    ]

    static func validated(name: String, webURL: String) -> TrackerConnection? {
        guard let tracker = Tracker(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines)),
              tracker.rawValue.lowercased() != "gh" else { return nil }
        let value = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            guard let url = URLComponents(string: value), url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        }
        return .init(tracker: tracker, webURL: value.hasSuffix("/") ? String(value.dropLast()) : value)
    }

    func destination(key: String) -> String? {
        webURL.isEmpty ? nil : "\(webURL)/issues/\(key)"
    }
}

/// Synchronous snapshots keep OCR planning deterministic; only the refresh actor
/// performs reads. No credential or OCR content is stored in the directory.
final class TrackerDirectory: @unchecked Sendable {
    static let shared = TrackerDirectory()
    private let lock = NSLock()
    private var storedConnections: [TrackerConnection]
    private var storedProjects: [ProjectDescriptor]
    private let persists: Bool

    init(connections: [TrackerConnection]? = nil, projects: [ProjectDescriptor]? = nil, persists: Bool = true) {
        self.persists = persists
        storedConnections = connections ?? UserDefaults.standard.data(forKey: "trackerConnectionsV1")
            .flatMap { try? JSONDecoder().decode([TrackerConnection].self, from: $0) } ?? TrackerConnection.defaults
        storedProjects = projects ?? UserDefaults.standard.data(forKey: "trackerProjectsV1")
            .flatMap { try? JSONDecoder().decode([ProjectDescriptor].self, from: $0) } ?? []
    }

    var connections: [TrackerConnection] { lock.lock(); defer { lock.unlock() }; return storedConnections }
    var projects: [ProjectDescriptor] {
        lock.lock(); defer { lock.unlock() }
        let enabled = Set(storedConnections.map(\.tracker))
        return storedProjects.filter { enabled.contains($0.tracker) }
    }

    func replace(connections: [TrackerConnection], projects: [ProjectDescriptor], persist: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        storedConnections = connections; storedProjects = projects
        if persist && persists {
            UserDefaults.standard.set(try? JSONEncoder().encode(connections), forKey: "trackerConnectionsV1")
            UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: "trackerProjectsV1")
        }
    }

    func routes(for project: String, preferred: Tracker? = nil, allowUndiscovered: Bool = false) -> [Tracker] {
        let enabled = connections.map(\.tracker)
        let canonical = project.uppercased() == "GLINT" ? "NUNCID" : project.uppercased()
        let discovered = Set(projects.filter { $0.key == canonical }.map(\.tracker))
        // OCR requires verified project ownership. Only intentional typed/pasted
        // keys may opt into probing instances when discovery is unavailable.
        let routes = discovered.isEmpty && allowUndiscovered ? enabled : enabled.filter { discovered.contains($0) }
        return preferred.map { p in routes.filter { $0 == p } + routes.filter { $0 != p } } ?? routes
    }

    func commit(projects: [ProjectDescriptor], ifConnections connections: [TrackerConnection]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storedConnections == connections else { return false }
        storedProjects = projects
        if persists { UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: "trackerProjectsV1") }
        return true
    }

    func tracker(forHost host: String) -> Tracker? {
        tracker(forBaseURL: "https://" + host)
    }

    func tracker(forBaseURL base: String) -> Tracker? {
        guard let target = URLComponents(string: base), target.scheme?.lowercased() == "https",
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil else { return nil }
        let matches = connections.filter {
            guard let url = URLComponents(string: $0.webURL) else { return false }
            return url.host?.lowercased() == target.host?.lowercased() && (url.port ?? 443) == (target.port ?? 443)
                && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return matches.count == 1 ? matches[0].tracker : nil
    }
}

actor TrackerDiscovery {
    static let shared = TrackerDiscovery()
    private var lastRefresh = Date.distantPast
    private var inFlight: (id: UUID, connections: [TrackerConnection], task: Task<String, Never>)?
    private var lastUnknownRefresh = Date.distantPast
    private var unknownMisses: [String: Date] = [:]
    private var lastRefreshComplete = false
    private let directory: TrackerDirectory
    private let read: @Sendable (Tracker) async -> Data?

    init(directory: TrackerDirectory = .shared,
         read: @escaping @Sendable (Tracker) async -> Data? = { await TicketResolver.readPaimos($0, ["project", "list", "--all"]) }) {
        self.directory = directory
        self.read = read
    }

    func refreshUnknownProjects(_ keys: Set<String>) async {
        let now = Date()
        unknownMisses = unknownMisses.filter { now.timeIntervalSince($0.value) < 300 }
        let missing = keys.filter { directory.routes(for: $0).isEmpty && unknownMisses[$0] == nil }
        guard !missing.isEmpty, now.timeIntervalSince(lastUnknownRefresh) >= 30 else { return }
        _ = await refresh(force: true)
        lastUnknownRefresh = Date()
        if lastRefreshComplete {
            for key in missing where directory.routes(for: key).isEmpty { unknownMisses[key] = Date() }
        }
    }

    /// Failed instances keep their last successful directory for offline use.
    func refresh(force: Bool = false) async -> String {
        if let flight = inFlight {
            let result = await flight.task.value
            if inFlight?.id == flight.id { inFlight = nil }
            if directory.connections != flight.connections { return await refresh(force: true) }
            return result
        }
        guard force || Date().timeIntervalSince(lastRefresh) >= 300 else { return "Projects are up to date." }
        let id = UUID(), connections = directory.connections
        // This task is shared and unstructured: cancellation of one OCR viewport
        // must not discard discovery needed by a newer viewport or Settings.
        let task = Task { await self.performRefresh(connections: connections) }
        inFlight = (id, connections, task)
        let result = await task.value
        if inFlight?.id == id { inFlight = nil }
        if directory.connections != connections { return await refresh(force: true) }
        return result
    }

    private func performRefresh(connections: [TrackerConnection]) async -> String {
        var projects = directory.projects
        var failures: [String] = []
        for connection in connections {
            guard let data = await read(connection.tracker),
                  let found = Self.decodeProjects(data, tracker: connection.tracker) else {
                failures.append(connection.id); continue
            }
            projects.removeAll { $0.tracker == connection.tracker }
            projects.append(contentsOf: found)
        }
        // A settings edit during a read must not resurrect removed instances.
        guard directory.commit(projects: projects, ifConnections: connections) else { return "Instances changed; refresh again." }
        lastRefresh = Date()
        lastRefreshComplete = failures.isEmpty
        let summary = "\(projects.count) available projects; refreshed \(connections.count - failures.count) instances."
        return failures.isEmpty ? summary : summary + " Could not read: \(failures.joined(separator: ", ")). Check local paimos authentication."
    }

    static func decodeProjects(_ data: Data, tracker: Tracker) -> [ProjectDescriptor]? {
        guard let values = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return values.compactMap { project in
            guard let rawKey = project["key"] as? String else { return nil }
            let key = rawKey.uppercased()
            guard key.range(of: #"\A[A-Z][A-Z0-9]{1,11}\z"#, options: .regularExpression) != nil,
                  seen.insert(key).inserted else { return nil }
            let hints = ProjectDescriptor.presentationHints.first { $0.key == key }
            return ProjectDescriptor(key: key, name: String((project["name"] as? String ?? key).prefix(200)), aliases: hints?.aliases ?? [], tracker: tracker)
        }.sorted { $0.key < $1.key }
    }
}
