import Foundation

enum TrackerDirectoryChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        let extra = Tracker(rawValue: "another-instance")!
        let connection = TrackerConnection(tracker: extra, endpoints: ["https://tickets.example"])
        let data = Data(#"[{"key":"HNET","name":"Home network"},{"key":"FRESH","name":"New project"},{"key":"HNET","name":"Duplicate"},{"key":"--bad","name":"Invalid"}]"#.utf8)
        let found = TrackerDiscovery.decodeProjects(data, tracker: extra) ?? []
        check(found.map(\.key) == ["FRESH", "HNET"], "discover new project, validate and deduplicate keys")
        let directory = TrackerDirectory(connections: TrackerConnection.defaults + [connection], projects: found)
        check(directory.routes(for: "HNET", preferred: .pma) == [extra], "discovered owner wins over history")
        check(directory.routes(for: "UNSEEN").isEmpty, "unknown screen keys require catalog refresh")
        check(directory.routes(for: "UNSEEN", allowUndiscovered: true) == [.ppm, .pma, extra], "intentional entry may try configured instances")
        check(directory.tracker(forHost: "tickets.example") == extra, "custom browser URL route")
        check(directory.tracker(forHost: "tickets.example.evil") == nil, "host matching is exact")
        let collision = found + [ProjectDescriptor(key: "HNET", name: "Other HNET", aliases: [], tracker: .ppm)]
        check(ProjectMatcher.cycle(1, projects: [], current: "HNET", tracker: .ppm) == nil, "empty catalog cannot crash project cycling")
        check(ProjectMatcher.bestMatch(for: "HNET", projects: []) == nil, "empty catalog has no project match")
        check(ProjectMatcher.cycle(1, projects: collision, current: "HNET", tracker: extra)?.tracker == .ppm, "cycle reaches duplicate project on next instance")
        check(ProjectMatcher.cycle(1, projects: collision, current: "HNET", tracker: .ppm)?.key == "FRESH", "cycle leaves duplicate namespace and wraps")
        directory.replace(connections: TrackerConnection.defaults + [connection], projects: collision, persist: false)
        check(directory.routes(for: "HNET") == [.ppm, extra], "duplicate project keys retain separate namespaces")
        directory.replace(connections: TrackerConnection.defaults, projects: found, persist: false)
        check(!directory.projects.contains { $0.tracker == extra }, "removed instances stop participating")
        check(TrackerConnection.validated(name: "--bad", endpoints: []) == nil, "option-like profile rejected")
        check(TrackerConnection.validated(name: "Gh", endpoints: []) == nil, "GitHub provider name is reserved")
        check(Tracker(rawValue: "ppm\n") == nil, "newline profile rejected")
        check(TicketResolver.matchesIssueKey(requested: "GLINT-12", returned: "NUNCID-12"), "historical key redirect retained")
        check(!TicketResolver.matchesIssueKey(requested: "HNET-12", returned: "NUNCID-12"), "mismatched response rejected")
        for invalid in ["https://user:pass@example.com", "http://example.com", "https://example.com/?key=value", "https://example.com/#fragment", ""] {
            check(TrackerConnection.validated(name: "ok", endpoints: ["https://tickets.example", invalid]) == nil, "every endpoint is validated: \(invalid)")
            check(connection.addingEndpoint(invalid) == nil, "invalid endpoint cannot be added: \(invalid)")
        }
        check((try? JSONDecoder().decode(Tracker.self, from: Data(#""ppm""#.utf8))) == .ppm, "legacy tracker history decodes")
        check((try? JSONDecoder().decode(Tracker.self, from: JSONEncoder().encode(extra))) == extra, "additional tracker roundtrip")
        let references = ScreenReferenceClassifier.classify(.init(lines: ["HNET-130 | One origin for all floors", "HNET-131 | One outline"]))
        check(references.filter(\.isVisibleCandidate).count == 2 && references.allSatisfy { $0.decision == .unresolved }, "HNET screenshot shape requests discovery before reads")
        check(references.flatMap(\.lookupSpecs).isEmpty, "unseen screenshot key is not broadcast")
        let explicit = ScreenReferenceClassifier.classify(.init(lines: ["https://pm.barta.cm/issues/HNET-130"]))
        check(explicit.first?.lookupSpecs == [.issue(tracker: .ppm, key: "HNET-130")], "explicit URL never crosses instances")
        let originalConnections = TrackerDirectory.shared.connections
        let originalProjects = TrackerDirectory.shared.projects
        defer { TrackerDirectory.shared.replace(connections: originalConnections, projects: originalProjects, persist: false) }
        TrackerDirectory.shared.replace(connections: [connection], projects: found, persist: false)
        let discoveredReference = ["HNET-130", "HNET issue 131", "FRESH 42"].flatMap { ScreenReferenceClassifier.classify(.init(lines: [$0])) }
        check(discoveredReference.compactMap(\.spec) == [
            .issue(tracker: extra, key: "HNET-130"), .issue(tracker: extra, key: "HNET-131"), .issue(tracker: extra, key: "FRESH-42")
        ], "refreshed directory changes classification without restarting")
        check(ProjectDescriptor.selectable.contains { $0.key == "HNET" && $0.tracker == extra }, "new projects reach selector")
        let customURL = ScreenReferenceClassifier.classify(.init(lines: ["https://tickets.example/issues/HNET-130"]))
        check(customURL.first?.lookupSpecs == [.issue(tracker: extra, key: "HNET-130")], "custom URL stays on explicit instance")
        let bare = NearbyToken(raw: "42", kind: .bareNumber(42), sourceOrder: 0)
        check(CandidatePlanner.candidates(for: bare, context: .init(lastSeenTracker: .ppm, ppmProject: "PAI", pmaProject: "START")).allSatisfy {
            if case .issue = $0 { return false }; return true
        }, "additional instances need intentional remembered project for bare numbers")
        TrackerDirectory.shared.replace(connections: [], projects: [], persist: false)
        check(ScreenReferenceClassifier.classify(.init(lines: ["ticket 42", "HNET-130"])).flatMap(\.lookupSpecs).isEmpty, "empty configuration never dispatches")
        TrackerDirectory.shared.replace(connections: TrackerConnection.defaults, projects: [], persist: false)
        let emptyContext = ResolutionContext(lastSeenTracker: .ppm, ppmProject: "PAI", pmaProject: "START")
        check(EvidenceCandidatePlanner.plan(input: .init(lines: ["ZZZ-1"]), context: emptyContext).proposals.isEmpty, "legacy OCR planner never broadcasts unknown keys")
        TrackerDirectory.shared.replace(connections: [.init(tracker: .ppm, endpoints: [])], projects: [], persist: false)
        check(TicketLine(key: "NUNCID-1", state: "open", title: "Fixture", source: "ppm").destinationURL == nil, "empty browser URL does not fall back to hardcoded host")
        let pathConnection = TrackerConnection(tracker: extra, endpoints: ["https://tickets.example:8443/team"])
        TrackerDirectory.shared.replace(connections: [pathConnection], projects: [], persist: false)
        check(ScreenReferenceClassifier.classify(.init(lines: ["https://tickets.example:8443/team/issues/HNET-130"])).flatMap(\.lookupSpecs) == [.issue(tracker: extra, key: "HNET-130")], "custom ports and path prefixes route explicitly")
        check(ScreenReferenceClassifier.classify(.init(lines: ["https://tickets.example:8443/team/p/HNET/HNET-130"])).flatMap(\.lookupSpecs) == [.issue(tracker: extra, key: "HNET-130")], "AEON links preserve custom ports and path prefixes")
        check(pathConnection.destination(key: "HNET-130") == "https://tickets.example:8443/team/p/HNET/HNET-130", "custom endpoint generates AEON links")
        check(pathConnection.destination(key: "A B/C-12?x#%") == "https://tickets.example:8443/team/p/A%20B%2FC/A%20B%2FC-12%3Fx%23%25", "project and canonical key are escaped as separate segments")
        check(pathConnection.destination(key: "invalid") == nil, "ticket destination needs a project in the key")
        failures.append(contentsOf: endpointPersistenceChecks())

        TrackerDirectory.shared.replace(connections: TrackerConnection.defaults, projects: [], persist: false)
        let issue = Data(#"{"issue_key":"NUNCID-111","title":"Canonical redirect","status":"open"}"#.utf8)
        let canonical = TicketResolver.issueLine(data: issue, tracker: .ppm, key: "GLINT-111")
        check(canonical?.key == "NUNCID-111" && canonical?.destination == "https://aeon.barta.cm/p/NUNCID/NUNCID-111", "resolver links use the canonical server key and project")
        check(TicketResolver.issueLine(data: issue, tracker: .ppm, key: "HNET-111") == nil, "canonical destination does not bypass response identity validation")
        let cached = TicketLine(key: "NUNCID-111", state: "open", title: "Cached", source: "ppm", destination: "https://pm.barta.cm/issues/NUNCID-111")
        check(cached.destinationURL?.absoluteString == "https://aeon.barta.cm/p/NUNCID/NUNCID-111", "cached destinations follow migrated settings")
        TrackerDirectory.shared.replace(connections: [TrackerConnection.defaults[0].makingPrimary(at: 1)], projects: [], persist: false)
        check(cached.destinationURL?.absoluteString == "https://pm.barta.cm/p/NUNCID/NUNCID-111", "cached destinations follow a primary change")
        TrackerDirectory.shared.replace(connections: [.init(tracker: .ppm, endpoints: [])], projects: [], persist: false)
        check(cached.destinationURL == nil, "cached destinations respect an empty browser configuration")
        let aliases = TrackerConnection(tracker: extra, endpoints: ["https://primary.example", "https://alias.example:443/team", "https://alias.example:443/team"])
        let aliasDirectory = TrackerDirectory(connections: [aliases], projects: [], persists: false)
        check(aliasDirectory.tracker(forBaseURL: "https://ALIAS.example/team") == extra, "matching aliases counts instances rather than endpoints and normalizes default ports")
        let sharedEndpoint = TrackerConnection(tracker: .ppm, endpoints: ["https://alias.example/team"])
        aliasDirectory.replace(connections: [aliases, sharedEndpoint], projects: [], persist: false)
        check(aliasDirectory.tracker(forBaseURL: "https://alias.example/team") == nil, "endpoint configured on two instances is ambiguous")
        TrackerDirectory.shared.replace(connections: [aliases, sharedEndpoint], projects: [], persist: false)
        for path in ["/p/HNET/HNET-130", "/issues/HNET-130"] {
            check(ScreenReferenceClassifier.classify(.init(lines: ["https://alias.example/team" + path])).flatMap(\.lookupSpecs).isEmpty, "ambiguous primary or alias never dispatches: \(path)")
        }
        let encodedPrefix = TrackerConnection(tracker: extra, endpoints: ["https://tickets.example/team%20space/"])
        check(encodedPrefix.destination(key: "HNET-130") == "https://tickets.example/team%20space/p/HNET/HNET-130", "encoded endpoint path prefixes are not double escaped")
        return failures
    }

    private static func endpointPersistenceChecks() -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        let domain = "nuncid.endpoint-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let fresh = TrackerDirectory(projects: [], defaults: defaults)
        check(fresh.connections == TrackerConnection.defaults, "fresh install has both new primaries and legacy aliases")
        check(fresh.connections.map { $0.destination(key: "NUNCID-111") } == [
            "https://aeon.barta.cm/p/NUNCID/NUNCID-111", "https://pm.augmentoring.com/p/NUNCID/NUNCID-111"
        ], "PPM and PMA defaults generate direct AEON links")
        check(TrackerDirectory(projects: [], defaults: defaults).connections == fresh.connections, "fresh defaults survive a relaunch")
        defaults.removePersistentDomain(forName: domain)

        let legacy = Data(#"[{"tracker":"ppm","webURL":"https://pm.barta.cm"},{"tracker":"pma","webURL":"https://paimos.agm.ng"},{"tracker":"custom","webURL":"https://custom.example/team/"},{"tracker":"empty","webURL":""},{"tracker":"almost","webURL":"https://pm.barta.cm/"}]"#.utf8)
        defaults.set(legacy, forKey: "trackerConnectionsV1")
        let migrated = TrackerDirectory(projects: [], defaults: defaults)
        check(Array(migrated.connections.prefix(2)) == TrackerConnection.defaults, "both saved old defaults migrate to new primaries plus aliases")
        check(migrated.connections[2].endpoints == ["https://custom.example/team/"] && migrated.connections[3].endpoints.isEmpty
            && migrated.connections[4].endpoints == ["https://pm.barta.cm/"], "migration leaves custom and empty URLs untouched")
        check(defaults.data(forKey: "trackerConnectionsV1") == legacy, "migration preserves original V1 bytes for rollback")
        check(defaults.bool(forKey: "trackerEndpointsMigratedV1"), "successful migration records its one-time marker")
        check(TrackerDirectory(projects: [], defaults: defaults).connections == migrated.connections, "migration is idempotent on relaunch")

        let exactDomain = "nuncid.endpoint-exact-checks.\(UUID().uuidString)"
        let exactDefaults = UserDefaults(suiteName: exactDomain)!
        defer { exactDefaults.removePersistentDomain(forName: exactDomain) }
        exactDefaults.set(Data(#"[{"tracker":"ppm","webURL":"https://pm.barta.cm/"},{"tracker":"pma","webURL":""}]"#.utf8), forKey: "trackerConnectionsV1")
        let exact = TrackerDirectory(projects: [], defaults: exactDefaults)
        check(exact.connections.map(\.endpoints) == [["https://pm.barta.cm/"], []], "known profiles keep nonexact old URLs and intentionally empty browser settings")
        exactDefaults.removePersistentDomain(forName: exactDomain)
        exactDefaults.set(Data(#"[{"tracker":"ppm","webURL":"https://custom.example/team"},{"tracker":"pma","webURL":"https://custom-pma.example"}]"#.utf8), forKey: "trackerConnectionsV1")
        check(TrackerDirectory(projects: [], defaults: exactDefaults).connections.map(\.endpoints) == [["https://custom.example/team"], ["https://custom-pma.example"]], "custom PPM and PMA URLs are never replaced by defaults")
        exactDefaults.removePersistentDomain(forName: exactDomain)
        exactDefaults.set(Data("[]".utf8), forKey: "trackerConnectionsV1")
        check(TrackerDirectory(projects: [], defaults: exactDefaults).connections.isEmpty, "intentionally empty instance lists remain empty after migration")

        let restoredOld = TrackerConnection(tracker: .ppm, endpoints: ["https://pm.barta.cm"])
        migrated.replace(connections: [restoredOld], projects: [])
        check(TrackerDirectory(projects: [], defaults: defaults).connections == [restoredOld], "an old host chosen after migration is never migrated again")
        defaults.removeObject(forKey: "trackerConnectionsV2")
        check(TrackerDirectory(projects: [], defaults: defaults).connections.first == restoredOld, "one-time marker also prevents re-migration of V1")

        let base = TrackerConnection(tracker: .ppm, endpoints: ["https://first.example"])
        let added = base.addingEndpoint(" https://second.example/ ")!.addingEndpoint("https://third.example")!
        check(added.endpoints.count == 3 && added.tracker == base.tracker, "add multiple endpoints without replacing the profile")
        check(added.addingEndpoint("https://second.example") == nil, "duplicate endpoint addition rejected")
        let primary = added.makingPrimary(at: 2)
        let removed = primary.removingEndpoint(at: 1)
        check(removed.endpoints == ["https://third.example", "https://second.example"], "make primary and remove preserve ordered aliases")
        let project = ProjectDescriptor(key: "NUNCID", name: "Nuncid", aliases: [], tracker: .ppm)
        migrated.replace(connections: [removed], projects: [project])
        let relaunched = TrackerDirectory(defaults: defaults)
        check(relaunched.connections == [removed] && relaunched.projects == [project], "endpoint edits and the existing profile catalog survive relaunch")
        check(relaunched.tracker(forHost: "second.example") == .ppm && relaunched.tracker(forHost: "first.example") == nil, "only remaining aliases recognize links after relaunch")
        let empty = removed.removingEndpoint(at: 0).removingEndpoint(at: 0)
        relaunched.replace(connections: [empty], projects: [project])
        check(TrackerDirectory(defaults: defaults).connections == [empty] && empty.destination(key: "NUNCID-111") == nil, "removing the last endpoint retains the instance across relaunch")
        check((try? JSONDecoder().decode(TrackerConnection.self, from: JSONEncoder().encode(removed))) == removed, "multiple endpoints roundtrip in the new format")

        defaults.removePersistentDomain(forName: domain)
        let invalid = Data("undecodable settings".utf8)
        defaults.set(invalid, forKey: "trackerConnectionsV1")
        check(TrackerDirectory(projects: [], defaults: defaults).connections.isEmpty
            && defaults.data(forKey: "trackerConnectionsV1") == invalid
            && defaults.data(forKey: "trackerConnectionsV2") == nil
            && !defaults.bool(forKey: "trackerEndpointsMigratedV1"), "failed decoding retains saved data and permits a later migration retry")
        defaults.set(invalid, forKey: "trackerConnectionsV2")
        check(TrackerDirectory(projects: [], defaults: defaults).connections.isEmpty
            && defaults.data(forKey: "trackerConnectionsV2") == invalid, "undecodable V2 settings are preserved without enabling defaults")
        return failures
    }
}

private actor DirectoryReadFixture {
    var calls: [Tracker: Int] = [:]
    var fails = false
    func setFailure() { fails = true }
    func read(_ tracker: Tracker) async -> Data? {
        calls[tracker, default: 0] += 1
        try? await Task.sleep(nanoseconds: 80_000_000)
        return fails ? nil : Data(#"[{"id":1,"key":"HNET","name":"Home network","status":"active"},{"key":"NONAME","name":null}]"#.utf8)
    }
}

enum TrackerDiscoveryChecks {
    static func run() async -> [String] {
        var failures: [String] = []
        let connection = TrackerConnection.defaults[0]
        let directory = TrackerDirectory(connections: [connection], projects: [], persists: false)
        let reads = DirectoryReadFixture()
        let discovery = TrackerDiscovery(directory: directory, read: { await reads.read($0) })
        let cancelledWaiter = Task { await discovery.refresh(force: true) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        cancelledWaiter.cancel()
        _ = await discovery.refresh(force: true)
        _ = await cancelledWaiter.value
        if await reads.calls[.ppm] != 1 || directory.routes(for: "HNET") != [.ppm] {
            failures.append("shared discovery survives caller cancellation and coalesces reads")
        }
        if !directory.projects.contains(where: { $0.key == "NONAME" && $0.name == "NONAME" }) {
            failures.append("one nameless row must not discard the catalog")
        }
        await discovery.refreshUnknownProjects(["MISSING"])
        let callsAfterMiss = await reads.calls[.ppm]
        await discovery.refreshUnknownProjects(["MISSING"])
        await discovery.refreshUnknownProjects(["ANOTHER"])
        if await reads.calls[.ppm] != callsAfterMiss { failures.append("unknown refresh miss and throttle are bounded") }
        await reads.setFailure()
        _ = await discovery.refresh(force: true)
        if directory.routes(for: "HNET") != [.ppm] { failures.append("offline refresh retains known routes") }

        let replacement = TrackerConnection(tracker: Tracker(rawValue: "extra")!, endpoints: [])
        let racingReads = DirectoryReadFixture()
        let racing = TrackerDiscovery(directory: directory, read: { await racingReads.read($0) })
        let oldRefresh = Task { await racing.refresh(force: true) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        directory.replace(connections: [replacement], projects: [], persist: false)
        _ = await racing.refresh(force: true)
        _ = await oldRefresh.value
        if directory.connections != [replacement] || directory.routes(for: "HNET") != [replacement.tracker] {
            failures.append("settings changes queue a refresh without reviving removed instances")
        }
        return failures
    }
}
