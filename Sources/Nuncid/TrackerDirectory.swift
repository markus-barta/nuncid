import Foundation

struct TrackerConnection: Codable, Equatable, Identifiable, Sendable {
    let tracker: Tracker
    /// The first endpoint opens tickets; all endpoints recognize browser links.
    /// Authentication and API routing belong to the local paimos profile.
    let endpoints: [String]
    var id: String { tracker.rawValue }

    static let defaults: [TrackerConnection] = [
        .init(tracker: .ppm, endpoints: ["https://aeon.barta.cm", "https://pm.barta.cm"]),
        .init(tracker: .pma, endpoints: ["https://pm.augmentoring.com", "https://paimos.agm.ng"])
    ]

    private static let legacyDefaults: [Tracker: String] = [
        .ppm: "https://pm.barta.cm", .pma: "https://paimos.agm.ng"
    ]

    private enum CodingKeys: String, CodingKey { case tracker, endpoints, webURL }

    init(tracker: Tracker, endpoints: [String]) {
        self.tracker = tracker
        self.endpoints = endpoints
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tracker = try values.decode(Tracker.self, forKey: .tracker)
        if values.contains(.endpoints) {
            endpoints = try values.decode([String].self, forKey: .endpoints)
        } else {
            let legacyURL = try values.decode(String.self, forKey: .webURL)
            endpoints = legacyURL.isEmpty ? [] : [legacyURL]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tracker, forKey: .tracker)
        try values.encode(endpoints, forKey: .endpoints)
    }

    /// Exact old defaults only. Custom URLs and intentionally empty lists survive.
    func migratingLegacyDefault() -> Self {
        guard let legacy = Self.legacyDefaults[tracker], endpoints == [legacy] else { return self }
        return Self.defaults.first { $0.tracker == tracker } ?? self
    }

    static func validated(name: String, endpoints: [String]) -> TrackerConnection? {
        guard let tracker = Tracker(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines)),
              tracker.rawValue.lowercased() != "gh" else { return nil }
        let validated = endpoints.compactMap(validatedEndpoint)
        guard validated.count == endpoints.count else { return nil }
        return .init(tracker: tracker, endpoints: validated)
    }

    private static func validatedEndpoint(_ endpoint: String) -> String? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.url != nil else { return nil }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    func addingEndpoint(_ endpoint: String) -> Self? {
        guard let value = Self.validatedEndpoint(endpoint), !endpoints.contains(value) else { return nil }
        return .init(tracker: tracker, endpoints: endpoints + [value])
    }

    func removingEndpoint(at index: Int) -> Self {
        guard endpoints.indices.contains(index) else { return self }
        var updated = endpoints
        updated.remove(at: index)
        return .init(tracker: tracker, endpoints: updated)
    }

    func makingPrimary(at index: Int) -> Self {
        guard endpoints.indices.contains(index) else { return self }
        var updated = endpoints
        updated.insert(updated.remove(at: index), at: 0)
        return .init(tracker: tracker, endpoints: updated)
    }

    func destination(key: String) -> String? {
        let parts = key.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let segmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let endpoint = endpoints.first, Self.validatedEndpoint(endpoint) != nil,
              parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              let project = String(parts[0]).addingPercentEncoding(withAllowedCharacters: segmentCharacters),
              let issue = key.addingPercentEncoding(withAllowedCharacters: segmentCharacters),
              var url = URLComponents(string: endpoint) else { return nil }
        while url.percentEncodedPath.hasSuffix("/") { url.percentEncodedPath.removeLast() }
        url.percentEncodedPath += "/p/\(project)/\(issue)"
        return url.url?.absoluteString
    }
}

/// Synchronous snapshots keep OCR planning deterministic; only the refresh actor
/// performs reads. No credential or OCR content is stored in the directory.
final class TrackerDirectory: @unchecked Sendable {
    static let shared = TrackerDirectory(persists: !CommandLine.arguments.contains { $0.hasSuffix("self-test") })
    private let lock = NSLock()
    private var storedConnections: [TrackerConnection]
    private var storedProjects: [ProjectDescriptor]
    private let persists: Bool
    private let defaults: UserDefaults
    private static let connectionsKey = "trackerConnectionsV2"
    private static let migrationKey = "trackerEndpointsMigratedV1"

    init(connections: [TrackerConnection]? = nil, projects: [ProjectDescriptor]? = nil, persists: Bool = true,
         defaults: UserDefaults = .standard) {
        self.persists = persists
        self.defaults = defaults
        storedConnections = connections ?? Self.loadConnections(defaults: defaults, persist: persists)
        storedProjects = projects ?? defaults.data(forKey: "trackerProjectsV1")
            .flatMap { try? JSONDecoder().decode([ProjectDescriptor].self, from: $0) } ?? []
    }

    private static func loadConnections(defaults: UserDefaults, persist: Bool) -> [TrackerConnection] {
        if let saved = defaults.data(forKey: connectionsKey) {
            // Keep undecodable data intact and disable routing rather than activate defaults.
            return (try? JSONDecoder().decode([TrackerConnection].self, from: saved)) ?? []
        }
        let connections: [TrackerConnection]
        if let legacy = defaults.data(forKey: "trackerConnectionsV1") {
            guard let decoded = try? JSONDecoder().decode([TrackerConnection].self, from: legacy) else { return [] }
            connections = defaults.bool(forKey: migrationKey) ? decoded : decoded.map { $0.migratingLegacyDefault() }
        } else {
            connections = TrackerConnection.defaults
        }
        if persist, let saved = try? JSONEncoder().encode(connections) {
            // Leave V1 untouched as a rollback copy; subsequent launches prefer V2.
            defaults.set(saved, forKey: connectionsKey)
            defaults.set(true, forKey: migrationKey)
        }
        return connections
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
            defaults.set(try? JSONEncoder().encode(connections), forKey: Self.connectionsKey)
            defaults.set(try? JSONEncoder().encode(projects), forKey: "trackerProjectsV1")
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
        if persists { defaults.set(try? JSONEncoder().encode(projects), forKey: "trackerProjectsV1") }
        return true
    }

    func tracker(forHost host: String) -> Tracker? {
        tracker(forBaseURL: "https://" + host)
    }

    func tracker(forBaseURL base: String) -> Tracker? {
        guard let target = URLComponents(string: base), target.scheme?.lowercased() == "https",
              target.host?.isEmpty == false, target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil else { return nil }
        let matches = connections.filter { connection in
            connection.endpoints.contains { endpoint in
                guard let url = URLComponents(string: endpoint), url.scheme == "https",
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
                return url.host?.lowercased() == target.host?.lowercased() && (url.port ?? 443) == (target.port ?? 443)
                    && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return matches.count == 1 ? matches[0].tracker : nil
    }
}

actor TrackerDiscovery {
    static let shared = TrackerDiscovery(read: { tracker in
        guard !CommandLine.arguments.contains(where: { $0.hasSuffix("self-test") || $0.contains("capture-probe") }) else { return nil }
        return await TicketResolver.readPaimos(tracker, ["project", "list", "--all"])
    })
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
        let read = self.read
        let foundByTracker = await withTaskGroup(of: (Tracker, [ProjectDescriptor]?).self) { group in
            for connection in connections {
                group.addTask {
                    let data = await read(connection.tracker)
                    return (connection.tracker, data.flatMap { Self.decodeProjects($0, tracker: connection.tracker) })
                }
            }
            var found: [Tracker: [ProjectDescriptor]] = [:]
            for await (tracker, projects) in group {
                if let projects { found[tracker] = projects }
            }
            return found
        }
        // Keep instance order stable, regardless of which concurrent read finishes first.
        for connection in connections {
            guard let found = foundByTracker[connection.tracker] else {
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
