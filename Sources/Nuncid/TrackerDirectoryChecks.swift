import Foundation

enum TrackerDirectoryChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        let extra = Tracker(rawValue: "another-instance")!
        let connection = TrackerConnection(tracker: extra, webURL: "https://tickets.example")
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
        directory.replace(connections: TrackerConnection.defaults + [connection], projects: collision, persist: false)
        check(directory.routes(for: "HNET") == [.ppm, extra], "duplicate project keys retain separate namespaces")
        directory.replace(connections: TrackerConnection.defaults, projects: found, persist: false)
        check(!directory.projects.contains { $0.tracker == extra }, "removed instances stop participating")
        check(TrackerConnection.validated(name: "--bad", webURL: "") == nil, "option-like profile rejected")
        check(TrackerConnection.validated(name: "Gh", webURL: "") == nil, "GitHub provider name is reserved")
        check(Tracker(rawValue: "ppm\n") == nil, "newline profile rejected")
        check(TicketResolver.matchesIssueKey(requested: "GLINT-12", returned: "NUNCID-12"), "historical key redirect retained")
        check(!TicketResolver.matchesIssueKey(requested: "HNET-12", returned: "NUNCID-12"), "mismatched response rejected")
        check(TrackerConnection.validated(name: "ok", webURL: "https://user:pass@example.com") == nil, "URL credentials rejected")
        check(TrackerConnection.validated(name: "ok", webURL: "http://example.com") == nil, "non-HTTPS URL rejected")
        check(TrackerConnection.validated(name: "ok", webURL: "https://example.com/?key=value") == nil, "URL query rejected")
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
        TrackerDirectory.shared.replace(connections: [.init(tracker: .ppm, webURL: "")], projects: [], persist: false)
        check(TicketLine(key: "NUNCID-1", state: "open", title: "Fixture", source: "ppm").destinationURL == nil, "empty browser URL does not fall back to hardcoded host")
        let pathConnection = TrackerConnection(tracker: extra, webURL: "https://tickets.example:8443/team")
        TrackerDirectory.shared.replace(connections: [pathConnection], projects: [], persist: false)
        check(ScreenReferenceClassifier.classify(.init(lines: ["https://tickets.example:8443/team/issues/HNET-130"])).flatMap(\.lookupSpecs) == [.issue(tracker: extra, key: "HNET-130")], "custom ports and path prefixes route explicitly")
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

        let replacement = TrackerConnection(tracker: Tracker(rawValue: "extra")!, webURL: "")
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
