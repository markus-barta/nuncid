import Darwin
import AppKit
import Foundation

private final class SelfTestAsyncResult: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false

    func set(_ value: Bool) {
        lock.lock(); succeeded = value; lock.unlock()
    }

    func get() -> Bool {
        lock.lock(); let value = succeeded; lock.unlock(); return value
    }
}

private actor ResolverConcurrencyProbe {
    var calls: [String: Int] = [:]
    var active = 0
    var peak = 0
    func lookup(_ spec: CandidateSpec) async -> TicketLine? {
        calls[spec.cacheKey, default: 0] += 1
        active += 1; peak = max(peak, active)
        try? await Task.sleep(nanoseconds: 150_000_000)
        active -= 1
        return spec.cacheKey.contains("999999") ? nil : TicketLine(key: spec.cacheKey, state: "open", title: "Test fixture", source: "ppm")
    }
}

@MainActor enum SelfTests {
    private static func verifyResolverConcurrency() {
        let finished = DispatchSemaphore(value: 0)
        let result = SelfTestAsyncResult()
        Task.detached {
            let probe = ResolverConcurrencyProbe()
            let resolver = TicketResolver(lookupForTesting: { await probe.lookup($0) })
            let key = CandidateSpec.issue(tracker: .ppm, key: "NUNCID-63")
            let owner = Task { await resolver.resolve(key) }
            while await probe.calls[key.cacheKey] == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
            let waiter = Task { await resolver.resolve(key) }
            try? await Task.sleep(nanoseconds: 25_000_000)
            waiter.cancel()
            let cancelled = await waiter.value
            let first = await owner.value
            await withTaskGroup(of: Void.self) { group in
                for number in [63, 64, 64, 65, 66, 66] {
                    group.addTask { _ = await resolver.resolve(.issue(tracker: .ppm, key: "NUNCID-\(number)")) }
                }
            }
            let miss = CandidateSpec.issue(tracker: .ppm, key: "NUNCID-999999")
            _ = await resolver.resolve(miss)
            _ = await resolver.resolve(miss)
            let cachedMissCalls = await probe.calls[miss.cacheKey]
            await resolver.forgetMisses(for: [miss])
            _ = await resolver.resolve(miss)
            let counts = await probe.calls
            let peak = await probe.peak
            result.set(cancelled == nil && first != nil && counts[key.cacheKey] == 1
                && counts["issue:ppm:NUNCID-64"] == 1 && counts["issue:ppm:NUNCID-66"] == 1
                && cachedMissCalls == 1 && counts[miss.cacheKey] == 2
                && peak <= ExplorationPreferences.load().parallelLookups)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success, result.get() else {
            fputs("self-test failed: real resolver dedup, global limit, waiter cancellation and explicit miss retry\n", stderr); exit(1)
        }
    }

    private static func verifyMarkerAppearance() {
        let original = MarkerAppearancePreferences()
        guard MarkerVisualState.allCases.count == 3,
              original.unchecked.outlineColor == "#808080", original.unchecked.outlineOpacity == 0.7,
              !MarkerVisualState.unchecked.dash.isEmpty, original.unchecked.fillOpacity == 0,
              original.missed.outlineColor == "#555555", original.missed.strikeThroughEnabled,
              original.missed.strikeThroughOpacity == 0.5, MarkerVisualState.missed.dash.isEmpty,
              original.matched.outlineColor == "#34C759", original.matched.fillOpacity == 0.1,
              !original.matched.strikeThroughEnabled, !original.unchecked.strikeThroughEnabled else {
            fputs("self-test failed: three-state marker defaults\n", stderr); exit(1)
        }
        let suite = "nuncid-marker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sentinel", forKey: "inspectHotKey")
        let notified = SelfTestAsyncResult()
        let observer = NotificationCenter.default.addObserver(forName: .nuncidMarkerAppearanceDidChange, object: nil, queue: nil) { _ in notified.set(true) }
        defer { NotificationCenter.default.removeObserver(observer) }
        var preferences = original
        preferences[.matched].outlineColor = "123abc"
        preferences[.matched].outlineOpacity = 0.43
        preferences[.matched].fillColor = "#ABCDEF"
        preferences[.matched].fillOpacity = 0.17
        preferences[.matched].strikeThroughEnabled = true
        preferences[.matched].strikeThroughColor = "#CC1100"
        preferences[.matched].strikeThroughOpacity = 0.23
        preferences.persist(defaults: defaults)
        let restored = MarkerAppearancePreferences.load(defaults: defaults)
        guard restored == preferences.normalized, notified.get(),
              restored.unchecked == original.unchecked, restored.missed == original.missed,
              restored.matched.outlineColor == "#123ABC",
              defaults.string(forKey: "inspectHotKey") == "sentinel" else {
            fputs("self-test failed: independent marker preferences persist/notify without changing shortcuts\n", stderr); exit(1)
        }
        var bad = original.matched
        bad.outlineColor = "#oops"; bad.outlineOpacity = -5
        bad.fillOpacity = 5; bad.strikeThroughOpacity = .nan
        let fixed = bad.normalized(for: .matched)
        guard fixed.outlineColor == original.matched.outlineColor, fixed.outlineOpacity == 0,
              fixed.fillOpacity == 1, fixed.strikeThroughOpacity == 0.5,
              MarkerColor.normalized("#12345") == nil,
              MarkerColor.normalized("#12345678") == nil,
              MarkerColor.normalized(" 123456") == nil,
              MarkerColor.hex(MarkerColor.nsColor("#34C759")) == "#34C759" else {
            fputs("self-test failed: marker color/opacity normalization\n", stderr); exit(1)
        }
        defaults.set(Data("broken JSON".utf8), forKey: MarkerAppearancePreferences.defaultsKey)
        guard MarkerAppearancePreferences.load(defaults: defaults) == original else { exit(1) }

        func bitmap(_ style: MarkerStyle, state: MarkerVisualState, selected: Bool = false) -> NSBitmapImageRep {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 80,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            image.bitmapData!.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
            MarkerRenderer.draw(bounds: CGRect(x: 30, y: 20, width: 120, height: 30), state: state, selected: selected, style: style)
            NSGraphicsContext.restoreGraphicsState()
            return image
        }
        func peakAlpha(_ image: NSBitmapImageRep) -> CGFloat {
            (0..<80).flatMap { y in (0..<200).map { x in image.colorAt(x: x, y: y)!.alphaComponent } }.max()!
        }
        for selected in [false, true] {
            let fill = bitmap(original.matched, state: .matched, selected: selected)
            guard abs(fill.colorAt(x: 90, y: 40)!.alphaComponent - 0.1) < 0.01,
                  fill.colorAt(x: 159, y: 25)!.alphaComponent == 0 else {
                fputs("self-test failed: exact green fill opacity, no corner badges, selected opacity unchanged\n", stderr); exit(1)
            }
            let pending = bitmap(original.unchecked, state: .unchecked, selected: selected)
            guard peakAlpha(pending) <= 0.71, peakAlpha(pending) > 0.5 else { exit(1) }
        }
        var strike = original.missed
        strike.outlineOpacity = 0; strike.fillOpacity = 0
        let diagonal = bitmap(strike, state: .missed)
        guard peakAlpha(diagonal) > 0, peakAlpha(diagonal) <= 0.51 else { exit(1) }
        strike.strikeThroughEnabled = false
        guard peakAlpha(bitmap(strike, state: .missed)) == 0 else {
            fputs("self-test failed: strike-through opacity/toggle are independent of outline/fill\n", stderr); exit(1)
        }
    }

    private static func verifyExploration() {
        let states: [ExplorationOutcome] = [.matched, .queued, .resolving, .missed]
        guard states.filter({ $0.isNavigable(includeMisses: false) }) == [.matched, .queued, .resolving],
              states.allSatisfy({ $0.isNavigable(includeMisses: true) }),
              states.map(\.markerState) == [.matched, .unchecked, .unchecked, .missed],
              PopupScrollPresentationPolicy.opacity(pointerInside: false, recentlyScrolling: true, reduceTransparency: false) == 0.5,
              PopupScrollPresentationPolicy.opacity(pointerInside: true, recentlyScrolling: true, reduceTransparency: false) == 1,
              PopupScrollPresentationPolicy.opacity(pointerInside: false, recentlyScrolling: false, reduceTransparency: false) == 1,
              PopupScrollPresentationPolicy.opacity(pointerInside: false, recentlyScrolling: true, reduceTransparency: true) == 1,
              ExplorationPolicy.next(in: ["a", "b", "c"], selected: "c", direction: 1) == "a",
              ExplorationPolicy.next(in: ["a", "b", "c"], selected: "a", direction: -1) == "c",
              ExplorationPolicy.next(in: [], selected: nil, direction: 1) == nil,
              ExplorationPolicy.next(in: ["a", "miss", "b"], selected: "miss", direction: 1, eligible: ["a", "b"]) == "b",
              ExplorationPolicy.next(in: ["a", "miss", "b"], selected: "miss", direction: -1, eligible: ["a", "b"]) == "a",
              ExplorationPolicy.next(in: ["miss"], selected: "miss", direction: 1, eligible: []) == nil,
              ExplorationPolicy.sameOccurrence(CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 1, y: 1, width: 99, height: 19)),
              !ExplorationPolicy.sameOccurrence(CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 120, y: 0, width: 100, height: 20)),
              ExplorationPolicy.dispatch(pending: ["a", "b", "b", "c", "d"], running: ["a"], promoted: "d", limit: 3) == ["d", "b"],
              ExplorationPolicy.dispatch(pending: ["b"], running: ["a"], promoted: "b", limit: 1).isEmpty,
              ExplorationPolicy.dispatch(pending: ["a", "b", "c"], running: ["a", "b"], promoted: "c", limit: 1).isEmpty else {
            fputs("self-test failed: exploration navigation, dedup and bounded priority dispatch\n", stderr); exit(1)
        }
        let frame = CGRect(x: -1600, y: -500, width: 1400, height: 900)
        let point = CGPoint(x: -800, y: -60)
        let tiles = ExplorationPolicy.tiles(in: frame, around: point)
        let content = ExplorationPolicy.contentFrame(screen: frame, visible: frame, menuHeight: 32)
        guard content.maxY == frame.maxY - 32,
              !content.contains(CGPoint(x: frame.midX, y: frame.maxY - 10)),
              tiles.first?.contains(point) == true,
              tiles.allSatisfy({ frame.contains($0) }),
              stride(from: frame.minX, to: frame.maxX, by: 30).allSatisfy({ x in
                  stride(from: frame.minY, to: frame.maxY, by: 30).allSatisfy { y in tiles.contains { $0.contains(CGPoint(x: x, y: y)) } }
              }),
              ExplorationPolicy.tiles(in: .zero, around: .zero).isEmpty,
              ExplorationPolicy.tiles(in: CGRect(x: 0, y: 0, width: 30, height: 30), around: CGPoint(x: 15, y: 15)).count == 1 else {
            fputs("self-test failed: progressive tile coverage on offset displays\n", stderr); exit(1)
        }
        var dwell = ExplorationHover()
        let now = Date(timeIntervalSince1970: 1_000)
        guard dwell.update(candidate: "a", now: now, delay: 0.1) == nil,
              dwell.update(candidate: "a", now: now.addingTimeInterval(0.11), delay: 0.1) == "a",
              dwell.update(candidate: "a", now: now.addingTimeInterval(1), delay: 0.1) == nil,
              dwell.update(candidate: "b", now: now.addingTimeInterval(1), delay: 0) == "b",
              dwell.update(candidate: nil, now: now, delay: 0) == nil else {
            fputs("self-test failed: configurable once-per-entry hover dwell\n", stderr); exit(1)
        }
        let suite = "nuncid-exploration-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        guard ExplorationPreferences.load(defaults: defaults) == ExplorationPreferences() else { exit(1) }
        ExplorationPreferences(hoverMilliseconds: -1, parallelLookups: 99).persist(defaults: defaults)
        defaults.set("off", forKey: "activation.mode")
        ExplorationPreferences.migrateShortcutIfNeeded(defaults: defaults)
        guard ExplorationPreferences.load(defaults: defaults) == ExplorationPreferences(hoverMilliseconds: 0, parallelLookups: 5),
              NuncidPreferences.load(defaults: defaults).inspectHotKey == nil,
              NuncidPreferences.load(defaults: defaults).pinHotKey == .pin else {
            fputs("self-test failed: exploration preference clamps and disabled shortcut migration\n", stderr); exit(1)
        }
        NuncidPreferences.save(.inspect, key: "inspectHotKey", defaults: defaults)
        ExplorationPreferences.migrateShortcutIfNeeded(defaults: defaults)
        guard NuncidPreferences.load(defaults: defaults).inspectHotKey == .inspect else { exit(1) }
        for raw in ["00.01.01", "00.01.01.00.00.00", "24.02.29", "26.09.06.17.00.01", "99.12.31.23.59.59"] {
            guard let version = CalendarVersion(raw), CalendarVersion.fromMacOSShortVersion(version.macOSShortVersion)?.raw == raw else {
                fputs("self-test failed: injective macOS calendar mapping\n", stderr); exit(1)
            }
        }
        guard ["2026.229.0", "2026.0906.1", "2026.906.86401", "2100.101.1"].allSatisfy({ CalendarVersion.fromMacOSShortVersion($0) == nil }),
              CalendarVersion("26.09.06")?.macOSShortVersion != CalendarVersion("26.09.06.00.00.00")?.macOSShortVersion else { exit(1) }
        let finished = DispatchSemaphore(value: 0)
        let result = SelfTestAsyncResult()
        Task.detached {
            let budget = TrackerReadBudget()
            await budget.configure(1)
            let first = await budget.acquire()
            let waiter = Task { await budget.acquire() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            waiter.cancel()
            let cancelled = await waiter.value
            await budget.release()
            let next = await budget.acquire()
            await budget.release()
            result.set(first && !cancelled && next)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 2) == .success, result.get() else {
            fputs("self-test failed: global tracker budget/cancellation slot ownership\n", stderr); exit(1)
        }
    }

    private static func verifyMenuBarTargetSelection() {
        let start = Date(timeIntervalSince1970: 1_000)
        let target = CGPoint(x: 400, y: 300)
        let secondScreen = CGRect(x: 2000, y: -400, width: 1000, height: 800)
        guard !MenuBarTargetSelection.isContent(position: CGPoint(x: 2400, y: 390), screenFrame: secondScreen, menuHeight: 33),
              MenuBarTargetSelection.isContent(position: CGPoint(x: 2400, y: 350), screenFrame: secondScreen, menuHeight: 33),
              !MenuBarTargetSelection.isContent(position: target, screenFrame: secondScreen, menuHeight: 33) else {
            fputs("self-test failed: menu-bar exclusion on offset/notched displays\n", stderr); exit(1)
        }
        var selection = MenuBarTargetSelection(now: start)
        func time(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
        guard selection.update(position: .zero, eligible: false, now: time(0)) == .waiting,
              selection.update(position: .zero, eligible: false, now: time(2), clicked: true) == .waiting,
              selection.update(position: target, eligible: true, now: time(3)) == .waiting,
              selection.update(position: target, eligible: true, now: time(3.2)) == .waiting,
              selection.update(position: target, eligible: true, now: time(3.4)) == .scan(target),
              selection.update(position: target, eligible: true, now: time(3.5), clicked: true) == .cancelled else {
            fputs("self-test failed: menu selection waits outside bars, dwells, scans exactly once\n", stderr); exit(1)
        }
        var click = MenuBarTargetSelection(now: start)
        guard click.update(position: target, eligible: true, now: time(0.1), clicked: true) == .scan(target),
              click.update(position: target, eligible: true, now: time(1)) == .cancelled else {
            fputs("self-test failed: menu target click consumes one selection\n", stderr); exit(1)
        }
        var movement = MenuBarTargetSelection(now: start)
        let moved = CGPoint(x: 420, y: 300)
        guard movement.update(position: target, eligible: true, now: time(0)) == .waiting,
              movement.update(position: moved, eligible: true, now: time(0.2)) == .waiting,
              movement.update(position: moved, eligible: true, now: time(0.4)) == .waiting,
              movement.update(position: moved, eligible: false, now: time(0.5)) == .waiting,
              movement.update(position: moved, eligible: true, now: time(0.6)) == .waiting,
              movement.update(position: moved, eligible: true, now: time(1)) == .scan(moved) else {
            fputs("self-test failed: movement and re-entering a menu bar reset target dwell\n", stderr); exit(1)
        }
        var expired = MenuBarTargetSelection(now: start)
        var revoked = MenuBarTargetSelection(now: start)
        guard expired.update(position: target, eligible: true, now: time(15), clicked: true) == .cancelled,
              revoked.update(position: target, eligible: true, now: time(0.1), clicked: true,
                             permissionGranted: false) == .cancelled else {
            fputs("self-test failed: selection timeout and permission loss cancel before scanning\n", stderr); exit(1)
        }
    }

    private static func verifyMenuBarIconPresentation() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        guard let button = item.button else { fatalError("Missing test status button") }
        // Exercise the real status-button presenter across all state transitions.
        // Pixel contrast is owned by AppKit; these checks guard its prerequisites.
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
                               .accessibilityHighContrastDarkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            button.appearance = appearance
            for highlighted in [false, true] {
                button.highlight(highlighted)
                for mode in HoverActivationMode.allCases {
                    for hover in [false, true] {
                        for found in [false, true] {
                            button.contentTintColor = .systemRed
                            MenuBarIconPresentation.apply(to: button, mode: mode,
                                                          hoverEnabled: hover, matchFound: found)
                            guard button.image?.isTemplate == true,
                                  button.contentTintColor == nil,
                                  button.appearance === appearance,
                                  button.isEnabled,
                                  button.accessibilityLabel()?.hasPrefix("Nuncid,") == true else {
                                fputs("self-test failed: native menu-bar template appearance\n", stderr); exit(1)
                            }
                        }
                    }
                }
            }
        }
        button.appearance = nil
        MenuBarIconPresentation.apply(to: button, mode: .pressToScan, hoverEnabled: false, matchFound: false)
        guard button.appearance == nil, button.contentTintColor == nil else {
            fputs("self-test failed: status icon inherits menu-bar appearance\n", stderr); exit(1)
        }
    }

    static func runAndExit() -> Never {
        verifyMenuBarIconPresentation()
        verifyMenuBarTargetSelection()
        verifyExploration()
        verifyMarkerAppearance()
        verifyResolverConcurrency()
        let contextFailures = ScreenReferenceChecks.run()
        guard contextFailures.isEmpty else {
            fputs("self-test failed: screen reference context: \(contextFailures.joined(separator: "; "))\n", stderr); exit(1)
        }
        let tokens = TokenParser.parse([
            "HAUSV-578 PAI-843 START-186 PHAROS-203 JANUS-455",
            "collision #130 bare 130 release 0.99.12",
        ])
        guard tokens.map(\.raw) == [
            "HAUSV-578", "PAI-843", "START-186", "PHAROS-203", "JANUS-455",
            "#130", "130", "0.99.12",
        ] else {
            fputs("self-test failed: token parsing: \(tokens.map(\.raw))\n", stderr)
            exit(1)
        }

        let context = ResolutionContext(lastSeenTracker: .pma, ppmProject: "PHAROS", pmaProject: "START")
        guard CandidatePlanner.tracker(for: "HAUSV", context: context) == .ppm,
              CandidatePlanner.tracker(for: "NUNCID", context: context) == .ppm,
              CandidatePlanner.tracker(for: "START", context: context) == .pma else {
            fputs("self-test failed: tracker routing\n", stderr)
            exit(1)
        }
        guard HoverActivationMode.allCases.map(\.title) == ["Off", "Toggle Hover", "Press to Scan"],
              ActivationShortcutPolicy.action(for: .off) == .none,
              ActivationShortcutPolicy.action(for: .toggleHover) == .toggleHover,
              ActivationShortcutPolicy.action(for: .pressToScan) == .scanOnce,
              HoverMenuBarState.resolve(mode: .toggleHover, hoverEnabled: false, matchFound: true) == .inactive,
              HoverMenuBarState.resolve(mode: .toggleHover, hoverEnabled: true, matchFound: false) == .active,
              HoverMenuBarState.resolve(mode: .toggleHover, hoverEnabled: true, matchFound: true) == .matchFound,
              HoverMenuBarState.resolve(mode: .pressToScan, hoverEnabled: true, matchFound: true) == .inactive else {
            fputs("self-test failed: activation shortcut and menu bar state policy\n", stderr)
            exit(1)
        }
        let emittedHoverStates = [
            (false, false),
            (true, false),
            (true, true),
            (true, false),
        ].map { hoverEnabled, matchFound in
            HoverMenuBarState.resolve(
                mode: .toggleHover,
                hoverEnabled: hoverEnabled,
                matchFound: matchFound
            )
        }
        guard emittedHoverStates == [.inactive, .active, .matchFound, .active] else {
            fputs("self-test failed: emitted hover state drives the current menu bar icon\n", stderr)
            exit(1)
        }
        var menuBarScanCount = 0
        var menuBarOpenCount = 0
        MenuBarClickRouter.route(
            .left(controlKey: false),
            scanOnce: { menuBarScanCount += 1 },
            openMenu: { menuBarOpenCount += 1 }
        )
        guard menuBarScanCount == 1, menuBarOpenCount == 0,
              MenuBarClickRoutingPolicy.action(for: .left(controlKey: false)) == .scanOnce else {
            fputs("self-test failed: menu bar left click exactly-once routing\n", stderr)
            exit(1)
        }
        MenuBarClickRouter.route(
            .left(controlKey: true),
            scanOnce: { menuBarScanCount += 1 },
            openMenu: { menuBarOpenCount += 1 }
        )
        guard menuBarScanCount == 1, menuBarOpenCount == 1,
              MenuBarClickRoutingPolicy.action(for: .left(controlKey: true)) == .openMenu else {
            fputs("self-test failed: menu bar control-click zero-scan secondary routing\n", stderr)
            exit(1)
        }
        MenuBarClickRouter.route(
            .right,
            scanOnce: { menuBarScanCount += 1 },
            openMenu: { menuBarOpenCount += 1 }
        )
        guard menuBarScanCount == 1, menuBarOpenCount == 2,
              MenuBarClickRoutingPolicy.action(for: .right) == .openMenu else {
            fputs("self-test failed: menu bar right click zero-scan routing\n", stderr)
            exit(1)
        }
        guard MenuBarAccessibilityPolicy.openMenuActionName == "Open Nuncid menu" else {
            fputs("self-test failed: menu bar accessibility menu action\n", stderr)
            exit(1)
        }
        var menuActionCount = 0
        let menuActionTarget = MenuBarActionTarget { menuActionCount += 1 }
        let menuActionItem = NSMenuItem(
            title: "Dispatch probe",
            action: #selector(MenuBarActionTarget.invoke(_:)),
            keyEquivalent: ""
        )
        menuActionItem.target = menuActionTarget
        guard NSStringFromSelector(menuActionItem.action!) == "invoke:",
              NSApp.sendAction(menuActionItem.action!, to: menuActionItem.target, from: menuActionItem),
              menuActionCount == 1 else {
            fputs("self-test failed: menu item selector dispatches its retained action target\n", stderr)
            exit(1)
        }
        guard SemanticVersion("1.2.0") == SemanticVersion("1.2.0"),
              SemanticVersion("1.2.0")! > SemanticVersion("1.1.9")!,
              SemanticVersion("2.0.0")! > SemanticVersion("1.99.99")!,
              ["1.2", "1.2.3.4", "v1.2.3", "1.02.3", "1.-2.3", "1.2.x", ""].allSatisfy({ SemanticVersion($0) == nil }) else {
            fputs("self-test failed: strict semantic version parsing and comparison\n", stderr)
            exit(1)
        }
        guard AppUpdateState.checking.menuTitle == "Checking for updates…",
              AppUpdateState.current.menuTitle == "Nuncid is up to date",
              AppUpdateState.unavailable.menuTitle == "Update status unavailable",
              MenuUpdateHeaderPolicy.titles(installedVersion: "1.2.0", updateState: .checking) == [
                  "Nuncid version 1.2.0", "Checking for updates…"
              ] else {
            fputs("self-test failed: honest update menu copy\n", stderr)
            exit(1)
        }
        var knownLengthBody = BoundedResponseAccumulator(maximumBytes: 4)
        var unknownLengthBody = BoundedResponseAccumulator(maximumBytes: 4)
        guard BoundedResponseAccumulator.accepts(expectedContentLength: 4, maximumBytes: 4),
              !BoundedResponseAccumulator.accepts(expectedContentLength: 5, maximumBytes: 4),
              BoundedResponseAccumulator.accepts(
                  expectedContentLength: NSURLSessionTransferSizeUnknown,
                  maximumBytes: 4
              ),
              [UInt8]("good".utf8).allSatisfy({ knownLengthBody.append($0) }),
              knownLengthBody.data == Data("good".utf8),
              [UInt8]("good".utf8).allSatisfy({ unknownLengthBody.append($0) }),
              !unknownLengthBody.append(UInt8(ascii: "!")),
              unknownLengthBody.data == Data("good".utf8) else {
            fputs("self-test failed: bounded release response body\n", stderr)
            exit(1)
        }
        let validCalendar = ["26.08.31", "26.08.31.14.05.09", "24.02.29", "00.01.01.00.00.00"]
        let invalidCalendar = ["2026.08.31", "26.8.31", "26.02.29", "26.04.31", "26.08.31.24.00.00", "26.08.31.12.60.00", "26.08.31.12.00", "26.13.01", "26.00.10"]
        guard CalendarVersion("26.09.00") == nil,
              CalendarVersion("26.09.06\n") == nil,
              validCalendar.allSatisfy({ CalendarVersion($0) != nil }),
              invalidCalendar.allSatisfy({ CalendarVersion($0) == nil }) else {
            fputs("self-test failed: strict calendar version parsing (inspr-calendar-v1)\n", stderr)
            exit(1)
        }
        guard CalendarVersion("24.02.29")! < CalendarVersion("26.01.01")!,
              CalendarVersion("26.08.31")! < CalendarVersion("26.08.31.14.05.09")!,
              CalendarVersion("26.08.31")! == CalendarVersion("26.08.31.00.00.00")!,
              CalendarVersion("26.08.31.14.05.09")! < CalendarVersion("26.08.31.14.05.10")! else {
            fputs("self-test failed: calendar ordering (short form normalizes to 00.00.00)\n", stderr)
            exit(1)
        }
        func legacyIdentity(_ raw: String) -> ReleaseIdentity? {
            ReleaseIdentity(rawVersion: raw, scheme: .legacy)
        }
        func calendarIdentity(_ raw: String) -> ReleaseIdentity? {
            ReleaseIdentity(rawVersion: raw, scheme: .calendar, sequence: ReleaseMigration.firstCalendarSequence + (raw == "26.09.06" ? 0 : 1))
        }
        guard legacyIdentity("1.2.0") != nil,
              calendarIdentity("26.09.06") != nil,
              ReleaseIdentity.unclassified("1.2.0")?.scheme == .legacy,
              ReleaseIdentity.unclassified("26.08.31") == nil,
              ReleaseIdentity.unclassified("26.11.11") == nil,
              legacyIdentity("26.11.11") == nil,
              calendarIdentity("1.2.0") == nil,
              ReleaseIdentity.unclassified("Development") == nil else {
            fputs("self-test failed: release identity discrimination (ambiguous or invalid values fail closed)\n", stderr)
            exit(1)
        }
        guard calendarIdentity("26.09.06")!.isNewerThan(legacyIdentity("1.2.0")!) == true,
              legacyIdentity("1.2.0")!.isNewerThan(calendarIdentity("26.09.06")!) == false,
              legacyIdentity("2.0.0") == nil,
              SemanticVersion("26.09.06") == nil,
              SemanticVersion("1.2.1")! > SemanticVersion("1.2.0")!,
              calendarIdentity("26.09.06.10.30.00")!.isNewerThan(calendarIdentity("26.09.06")!) == true,
              calendarIdentity("26.09.06")!.isNewerThan(calendarIdentity("26.09.06.10.30.00")!) == false,
              calendarIdentity("26.09.06")!.isNewerThan(calendarIdentity("26.09.06")!) == false else {
            fputs("self-test failed: mixed-era and same-day release ordering through the migration anchor\n", stderr)
            exit(1)
        }
        func releasePayload(tag: String, url: String? = nil, prerelease: Bool = false, body: String? = nil) -> Data {
            let releaseURL = url ?? "https://github.com/markus-barta/nuncid/releases/tag/\(tag)"
            var payload: [String: Any] = ["tag_name": tag, "html_url": releaseURL,
                                          "draft": false, "prerelease": prerelease]
            if let body { payload["body"] = body }
            return try! JSONSerialization.data(withJSONObject: payload)
        }
        func calendarMetadata(_ version: String, sequence: Int, scheme: String = "inspr-calendar-v1") -> String {
            "\nSome user-facing release notes.\n\n<!-- nuncid-release-metadata\nversion-scheme: \(scheme)\nversion: \(version)\nrelease-channel: stable\nrelease-sequence: \(sequence)\n-->\n"
        }
        let firstSequence = ReleaseMigration.firstCalendarSequence
        let calendarRelease = releasePayload(tag: "v26.09.06", body: calendarMetadata("26.09.06", sequence: firstSequence))
        let nextSameDayRelease = releasePayload(tag: "v26.09.06.10.30.00", body: calendarMetadata("26.09.06.10.30.00", sequence: firstSequence + 1))
        let mismatchedMetadata = releasePayload(
            tag: "v26.09.06",
            body: calendarMetadata("26.09.07", sequence: 17)
        )
        let unknownSchemeMetadata = releasePayload(
            tag: "v26.09.06",
            body: calendarMetadata("26.09.06", sequence: 17, scheme: "semver")
        )
        let missingSequenceMetadata = releasePayload(
            tag: "v26.09.06",
            body: "\n<!-- nuncid-release-metadata\nversion-scheme: inspr-calendar-v1\nversion: 26.09.06\nrelease-channel: stable\n-->\n"
        )
        let canonicalEndpoint = CanonicalReleasePolicy.endpoint
        let metadata = calendarMetadata("26.09.06", sequence: firstSequence)
        let sequenceLine = "release-sequence: \(firstSequence)"
        let invalidBodies: [String?] = [
            nil, "", metadata.replacingOccurrences(of: "-->\n", with: ""),
            metadata + metadata,
            metadata.replacingOccurrences(of: "inspr-calendar-v1", with: "unknown"),
            metadata.replacingOccurrences(of: sequenceLine, with: "release-sequence: \(firstSequence - 1)"),
            metadata.replacingOccurrences(of: sequenceLine, with: "release-sequence: 0\(firstSequence)"),
            metadata.replacingOccurrences(of: "release-channel: stable", with: "release-channel: beta"),
            metadata.replacingOccurrences(of: "version: 26.09.06", with: "version: 26.09.07"),
            metadata.replacingOccurrences(of: sequenceLine, with: "version: 26.09.06\n\(sequenceLine)")
        ]
        guard invalidBodies.allSatisfy({ body in
            CanonicalReleasePolicy.evaluate(installed: legacyIdentity("1.2.1"),
                data: releasePayload(tag: "v26.09.06", body: body),
                responseURL: canonicalEndpoint, statusCode: 200) == .unavailable
        }),
        CanonicalReleasePolicy.evaluate(installed: legacyIdentity("1.2.0"),
            data: releasePayload(tag: "v1.2.1"), responseURL: canonicalEndpoint, statusCode: 200)
            == .available(version: "1.2.1", url: URL(string: "https://github.com/markus-barta/nuncid/releases/tag/v1.2.1")!),
        CanonicalReleasePolicy.evaluate(installed: legacyIdentity("1.2.1"),
            data: calendarRelease, responseURL: canonicalEndpoint, statusCode: 200)
            == .available(version: "26.09.06", url: URL(string: "https://github.com/markus-barta/nuncid/releases/tag/v26.09.06")!),
        ReleaseIdentity(rawVersion: "26.09.06", scheme: .calendar) == nil,
        ReleaseIdentity(rawVersion: "1.2.1", scheme: .legacy, sequence: 16) == nil,
        ReleaseIdentity(rawVersion: "26.09.06.10.30.00", scheme: .calendar, sequence: firstSequence)!
            .isNewerThan(calendarIdentity("26.09.06")!) == nil else {
            fputs("self-test failed: bridge metadata, sequence, and update-path gates\n", stderr); exit(1)
        }
        guard CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"), data: releasePayload(tag: "v1.2.0"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .available(
            version: "1.2.0",
            url: URL(string: "https://github.com/markus-barta/nuncid/releases/tag/v1.2.0")!
        ), CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.2.0"), data: releasePayload(tag: "v1.2.0"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .current,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.2.0"), data: releasePayload(tag: "v1.1.0"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .current,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"), data: releasePayload(tag: "v1.2.0", prerelease: true),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"), data: releasePayload(tag: "nightly"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"),
            data: releasePayload(tag: "v1.2.0", url: "https://example.com/markus-barta/nuncid/releases/tag/v1.2.0"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"), data: releasePayload(tag: "v1.2.0"),
            responseURL: URL(string: "https://api.github.com/repos/other/nuncid/releases/latest"), statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: nil, data: releasePayload(tag: "v1.2.0"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"), data: Data("not json".utf8),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.1.0"), data: releasePayload(tag: "v1.2.0"),
            responseURL: canonicalEndpoint, statusCode: 503
        ) == .unavailable else {
            fputs("self-test failed: canonical release update policy (legacy era)\n", stderr)
            exit(1)
        }
        guard CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.2.0"), data: calendarRelease,
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .available(
            version: "26.09.06",
            url: URL(string: "https://github.com/markus-barta/nuncid/releases/tag/v26.09.06")!
        ), CanonicalReleasePolicy.evaluate(
            installed: calendarIdentity("26.09.06"), data: calendarRelease,
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .current,
        CanonicalReleasePolicy.evaluate(
            installed: calendarIdentity("26.09.06"), data: releasePayload(tag: "v1.2.0"),
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .current,
        CanonicalReleasePolicy.evaluate(
            installed: calendarIdentity("26.09.06"), data: nextSameDayRelease,
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .available(
            version: "26.09.06.10.30.00",
            url: URL(string: "https://github.com/markus-barta/nuncid/releases/tag/v26.09.06.10.30.00")!
        ),
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.2.0"), data: mismatchedMetadata,
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.2.0"), data: unknownSchemeMetadata,
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable,
        CanonicalReleasePolicy.evaluate(
            installed: legacyIdentity("1.2.0"), data: missingSequenceMetadata,
            responseURL: canonicalEndpoint, statusCode: 200
        ) == .unavailable else {
            fputs("self-test failed: canonical release update policy (calendar era, metadata-discriminated)\n", stderr)
            exit(1)
        }
        guard let catalogueVersion = ReleaseHistory.notes.first?.version else {
            fputs("self-test failed: empty version history catalogue\n", stderr)
            exit(1)
        }
        let packagedVersion = NuncidBrand.version == "Development" ? catalogueVersion : NuncidBrand.version
        if Bundle.main.bundleIdentifier == "at.markusbarta.glint" {
            guard let rawScheme = Bundle.main.object(forInfoDictionaryKey: "NuncidVersionScheme") as? String,
                  let scheme = VersionScheme.parse(rawScheme),
                  let sequence = Bundle.main.object(forInfoDictionaryKey: "NuncidReleaseSequence") as? Int,
                  Bundle.main.object(forInfoDictionaryKey: "NuncidReleaseChannel") as? String == ReleaseMigration.channel,
                  let identity = ReleaseIdentity(rawVersion: packagedVersion, scheme: scheme, sequence: sequence),
                  let external = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  external == (identity.calendar?.macOSShortVersion ?? packagedVersion),
                  identity.calendar == nil || CalendarVersion.fromMacOSShortVersion(external)?.raw == packagedVersion else {
                fputs("self-test failed: packaged release identity\n", stderr); exit(1)
            }
        }
        guard ReleaseHistory.isValid(currentVersion: packagedVersion == "Development" ? catalogueVersion : packagedVersion),
              ReleaseHistory.notes.allSatisfy({ note in
                  note.items.allSatisfy { !$0.label.isEmpty && !$0.detail.isEmpty }
              }) else {
            fputs("self-test failed: positive version history catalogue\n", stderr)
            exit(1)
        }
        let bare = NearbyToken(raw: "203", kind: .bareNumber(203), sourceOrder: 0)
        guard CandidatePlanner.candidates(for: bare, context: context) == [
            .issue(tracker: .pma, key: "START-203"),
            .issue(tracker: .ppm, key: "PHAROS-203"),
            .pullRequest(number: 203, repo: "augmentoring-team/start-agm-com"),
        ] else {
            fputs("self-test failed: collision ordering\n", stderr)
            exit(1)
        }
        guard CandidatePlanner.repo(for: "NUNCID") == "markus-barta/nuncid",
              CandidatePlanner.repo(for: "GLINT") == "markus-barta/nuncid",
              CandidatePlanner.repo(for: "PAI") == "inspr-at/paimos",
              CandidatePlanner.repo(for: "UNKNOWN") == nil else {
            fputs("self-test failed: canonical repo routing\n", stderr)
            exit(1)
        }
        let first = TicketLine(key: "GLINT-7", state: "in-progress", title: "First", source: "ppm")
        let second = TicketLine(key: "#7", state: "open", title: "Second", source: "gh")
        guard HoverResultPolicy.visible(from: [nil, nil]).isEmpty,
              HoverResultPolicy.visible(from: [nil, first, nil, second, first]) == [first, second],
              HoverResultPolicy.visible(from: (1...20).map {
                  TicketLine(key: "PAI-\($0)", state: "open", title: "Result \($0)", source: "ppm")
              }).count == HoverResultPolicy.maximumResults else {
            fputs("self-test failed: visible result policy\n", stderr)
            exit(1)
        }
        let suite = "NuncidSelfTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fputs("self-test failed: isolated preferences\n", stderr)
            exit(1)
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("always", forKey: "triggerMode")
        let customInspect = HotKey(keyCode: 2, modifiers: [.command, .control], keyLabel: "D")
        let f19 = HotKey(keyCode: 80, modifiers: [], keyLabel: "F19")
        NuncidPreferences.save(customInspect, key: "inspectHotKey", defaults: defaults)
        NuncidPreferences.save(nil, key: "pinHotKey", defaults: defaults)
        guard NuncidPreferences.load(defaults: defaults) == NuncidPreferences(
            inspectHotKey: customInspect,
            pinHotKey: nil
        ) else {
            fputs("self-test failed: persisted preferences\n", stderr)
            exit(1)
        }
        NuncidPreferences.save(f19, key: "pinHotKey", defaults: defaults)
        guard NuncidPreferences.load(defaults: defaults).pinHotKey == f19 else {
            fputs("self-test failed: persisted F19 shortcut\n", stderr)
            exit(1)
        }
        let unsafePlainKey = HotKey(keyCode: 0, modifiers: [.shift], keyLabel: "A")
        let escape = HotKey(keyCode: 53, modifiers: [], keyLabel: "Esc")
        let backwardDelete = HotKey(keyCode: 51, modifiers: [], keyLabel: "Delete")
        let forwardDelete = HotKey(keyCode: 117, modifiers: [], keyLabel: "Forward Delete")
        guard HotKey.inspect.label == "⌥Space", HotKey.pin.label == "⌥⇧Space",
              HotKey.inspect.isSafeGlobalShortcut,
              HotKey(keyCode: 120, modifiers: [], keyLabel: "F2").isSafeGlobalShortcut,
              HotKey(keyCode: 122, modifiers: [], keyLabel: "F1").isSafeGlobalShortcut,
              HotKey(keyCode: 111, modifiers: [], keyLabel: "F12").isSafeGlobalShortcut,
              HotKey(keyCode: 105, modifiers: [], keyLabel: "F13").isSafeGlobalShortcut,
              f19.isSafeGlobalShortcut,
              HotKey(keyCode: 90, modifiers: [], keyLabel: "F20").isSafeGlobalShortcut,
              HotKey.functionKeyLabel(for: f19.keyCode) == "F19",
              !HotKey(keyCode: 123, modifiers: [], keyLabel: "←").isSafeGlobalShortcut,
              !unsafePlainKey.isSafeGlobalShortcut,
              ShortcutCapturePolicy.decision(for: f19, forbiddenHotKey: nil) == .accept(f19),
              ShortcutCapturePolicy.decision(for: unsafePlainKey, forbiddenHotKey: nil) == .rejectUnsafe,
              ShortcutCapturePolicy.decision(for: escape, forbiddenHotKey: nil) == .cancel,
              ShortcutCapturePolicy.decision(for: backwardDelete, forbiddenHotKey: nil) == .clear,
              ShortcutCapturePolicy.decision(for: forwardDelete, forbiddenHotKey: nil) == .clear,
              ShortcutCapturePolicy.decision(for: f19, forbiddenHotKey: f19) == .rejectDuplicate,
              NuncidPreferences.shortcutsConflict(inspect: .inspect, pin: .inspect),
              !NuncidPreferences.shortcutsConflict(inspect: .inspect, pin: .pin),
              !NuncidPreferences.shortcutsConflict(inspect: nil, pin: .pin) else {
            fputs("self-test failed: global shortcuts\n", stderr)
            exit(1)
        }
        guard PinCommandPolicy.action(for: .hidden) == .openPinned,
              PinCommandPolicy.action(for: .temporary) == .pinTemporary,
              PinCommandPolicy.action(for: .pinnedInactive) == .focusPinned,
              PinCommandPolicy.action(for: .pinnedActive) == .closePinned,
              PinCommandPolicy.clearsManualInspection(for: .openPinned),
              PinCommandPolicy.clearsManualInspection(for: .pinTemporary),
              !PinCommandPolicy.clearsManualInspection(for: .focusPinned),
              !PinCommandPolicy.clearsManualInspection(for: .closePinned) else {
            fputs("self-test failed: pin command state transitions\n", stderr)
            exit(1)
        }
        guard CircularNavigation.advancedIndex(current: 0, direction: -1, count: 3) == 2,
              CircularNavigation.advancedIndex(current: 2, direction: 1, count: 3) == 0,
              CircularNavigation.advancedIndex(current: 1, direction: 1, count: 3) == 2,
              CircularNavigation.advancedIndex(current: 7, direction: 1, count: 0) == 0 else {
            fputs("self-test failed: circular result navigation\n", stderr)
            exit(1)
        }
        let visibleFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
        guard PanelPlacement.clamped(origin: CGPoint(x: -500, y: 2_000), size: CGSize(width: 300, height: 200), visibleFrame: visibleFrame) == CGPoint(x: 108, y: 592),
              PanelPlacement.clamped(origin: CGPoint(x: 400, y: 350), size: CGSize(width: 300, height: 200), visibleFrame: visibleFrame) == CGPoint(x: 400, y: 350) else {
            fputs("self-test failed: screen clamping\n", stderr)
            exit(1)
        }
        var editing = PinnedEditState()
        editing.appendDigits("2"); editing.appendDigits("03")
        guard editing.numberBuffer == "203", editing.projectQuery.isEmpty,
              editing.backspace() == .number, editing.numberBuffer == "20" else {
            fputs("self-test failed: rapid numeric editing\n", stderr)
            exit(1)
        }
        editing.appendLetters("ph", currentProject: "START")
        editing.appendLetters("raos", currentProject: "START")
        guard editing.numberBuffer == nil, editing.projectQuery == "phraos", editing.projectBeforeQuery == "START",
              editing.backspace() == .project, editing.projectQuery == "phrao" else {
            fputs("self-test failed: project edit/revert state\n", stderr)
            exit(1)
        }
        editing.clear()
        guard !editing.hasInput else {
            fputs("self-test failed: clearing pinned input\n", stderr)
            exit(1)
        }
        let pasteTokens = TokenParser.parse(["PHAROS-203", "#123", "456"])
        guard pasteTokens.map(\.kind) == [.issueKey(project: "PHAROS", number: 203), .hashNumber(123), .bareNumber(456)] else {
            fputs("self-test failed: pasted ticket forms\n", stderr)
            exit(1)
        }
        let compactPRTokens = TokenParser.parse(["PR#42", "pr#43"])
        guard compactPRTokens.map(\.kind) == [.hashNumber(42), .hashNumber(43)] else {
            fputs("self-test failed: case-symmetric compact PR parsing\n", stderr); exit(1)
        }
        guard ProjectMatcher.bestMatch(for: "nunc")?.key == "NUNCID",
              ProjectMatcher.bestMatch(for: "phraos")?.key == "PHAROS",
              ProjectMatcher.bestMatch(for: "pamo")?.key == "PAI",
              ProjectMatcher.bestMatch(for: "haus")?.key == "HAUSV",
              ProjectMatcher.damerauLevenshtein("phraos", "pharos") == 1 else {
            fputs("self-test failed: fuzzy project matching\n", stderr)
            exit(1)
        }
        let pinned = PinnedTicketContext(project: "PAI", number: 843)
        pinned.persist(defaults: defaults)
        guard PinnedTicketContext.load(defaults: defaults, fallback: context) == pinned else {
            fputs("self-test failed: pinned ticket context\n", stderr)
            exit(1)
        }
        var activation = ActivationPreferences.defaults
        activation.mode = .toggleHover
        activation.scanFeedbackEnabled = false
        activation.persist(defaults: defaults)
        guard ActivationPreferences.load(defaults: defaults) == activation else {
            fputs("self-test failed: activation preference persistence\n", stderr)
            exit(1)
        }
        for (legacy, expected) in [("dwell", HoverActivationMode.toggleHover), ("continuous", .toggleHover), ("always", .toggleHover), ("option", .pressToScan), ("hold", .pressToScan), ("off", .off)] {
            let migrationSuite = "NuncidSelfTests.Migration.\(legacy).\(UUID().uuidString)"
            guard let migrationDefaults = UserDefaults(suiteName: migrationSuite) else { exit(1) }
            migrationDefaults.set(legacy, forKey: legacy == "always" || legacy == "option" ? "triggerMode" : "activation.mode")
            let migrated = ActivationPreferences.load(defaults: migrationDefaults)
            guard migrated.mode == expected,
                  migrationDefaults.string(forKey: "activation.mode") == expected.rawValue else {
                fputs("self-test failed: legacy activation migration \(legacy)\n", stderr); exit(1)
            }
            migrationDefaults.removePersistentDomain(forName: migrationSuite)
        }
        let corruptSuite = "NuncidSelfTests.CorruptActivation.\(UUID().uuidString)"
        guard let corruptDefaults = UserDefaults(suiteName: corruptSuite) else { exit(1) }
        corruptDefaults.set("not-a-mode", forKey: "activation.mode")
        guard ActivationPreferences.load(defaults: corruptDefaults).mode == ActivationPreferences.defaults.mode else {
            fputs("self-test failed: corrupt activation mode fallback\n", stderr); exit(1)
        }
        corruptDefaults.removePersistentDomain(forName: corruptSuite)
        guard !HoverInvocationPolicy.shouldTrigger(
            preferences: .init(mode: .off, scanFeedbackEnabled: true),
            hoverEnabled: true, stableDuration: 10, locationAlreadyScanned: false
        ), !HoverInvocationPolicy.shouldTrigger(
            preferences: activation,
            hoverEnabled: false, stableDuration: 10, locationAlreadyScanned: false
        ), !HoverInvocationPolicy.shouldTrigger(
            preferences: activation,
            hoverEnabled: true, stableDuration: ActivationPreferences.hoverSettleDuration - 0.001, locationAlreadyScanned: false
        ), HoverInvocationPolicy.shouldTrigger(
            preferences: activation,
            hoverEnabled: true, stableDuration: ActivationPreferences.hoverSettleDuration, locationAlreadyScanned: false
        ), !HoverInvocationPolicy.shouldTrigger(
            preferences: activation,
            hoverEnabled: true, stableDuration: 10, locationAlreadyScanned: true
        ) else {
            fputs("self-test failed: one-scan-per-location hover policy\n", stderr)
            exit(1)
        }
        guard ScanFeedbackLifecycleEvent.allCases.allSatisfy({
            ScanFeedbackLifecyclePolicy.permits($0, startedGeneration: 7, currentGeneration: 7)
        }), ScanFeedbackLifecycleEvent.allCases.allSatisfy({
            !ScanFeedbackLifecyclePolicy.permits($0, startedGeneration: 7, currentGeneration: 8)
        }) else {
            fputs("self-test failed: stale scan feedback lifecycle gate\n", stderr)
            exit(1)
        }
        guard QueuedScanLifecyclePolicy.shouldLaunch(
            queuedGeneration: 8, currentGeneration: 8, completedGeneration: 7
        ), !QueuedScanLifecyclePolicy.shouldLaunch(
            queuedGeneration: 8, currentGeneration: 9, completedGeneration: 7
        ), !QueuedScanLifecyclePolicy.shouldLaunch(
            queuedGeneration: 8, currentGeneration: 8, completedGeneration: 8
        ), QueuedScanLifecyclePolicy.shouldRetargetAfterPointerMovement(source: .explicitCommand),
           !QueuedScanLifecyclePolicy.shouldRetargetAfterPointerMovement(source: .menuTarget),
           !QueuedScanLifecyclePolicy.shouldRetargetAfterPointerMovement(source: .automaticHover) else {
            fputs("self-test failed: queued scan generation lifecycle\n", stderr); exit(1)
        }
        let normalPinnedCompletion = PinnedScanOwnershipPolicy.permitsCompletion(
            startedScanGeneration: 40,
            currentScanGeneration: 40,
            startedDirectGeneration: 7,
            currentDirectGeneration: 7,
            startedEditGeneration: 3,
            currentEditGeneration: 3
        )
        let lateResolvedCompletion = PinnedScanOwnershipPolicy.permitsCompletion(
            startedScanGeneration: 40,
            currentScanGeneration: 41,
            startedDirectGeneration: 7,
            currentDirectGeneration: 9,
            startedEditGeneration: 3,
            currentEditGeneration: 4
        )
        let lateNoMatchCompletion = PinnedScanOwnershipPolicy.permitsCompletion(
            startedScanGeneration: 40,
            currentScanGeneration: 41,
            startedDirectGeneration: 7,
            currentDirectGeneration: 8,
            startedEditGeneration: 3,
            currentEditGeneration: 4
        )
        guard PinnedScanOwnershipPolicy.shouldInvalidateForInput(alreadyClaimed: false),
              !PinnedScanOwnershipPolicy.shouldInvalidateForInput(alreadyClaimed: true),
              normalPinnedCompletion,
              !lateResolvedCompletion,
              !lateNoMatchCompletion else {
            fputs("self-test failed: pinned input owns late scan results/no-match\n", stderr); exit(1)
        }
        guard ScanCuePolicy.showsInvoked(for: .menuTarget),
              ScanCuePolicy.terminal(for: .menuTarget, hasResolvedResult: false) == .noMatch,
              ScanCuePolicy.showsInvoked(for: .explicitCommand),
              !ScanCuePolicy.showsInvoked(for: .automaticHover),
              ScanCuePolicy.terminal(for: .explicitCommand, hasResolvedResult: false) == .noMatch,
              ScanCuePolicy.terminal(for: .automaticHover, hasResolvedResult: false) == .none,
              ScanCuePolicy.terminal(for: .automaticHover, hasResolvedResult: true) == .none,
              ScanCuePolicy.terminal(for: .explicitCommand, hasResolvedResult: true) == .none else {
            fputs("self-test failed: explicit-versus-automatic scan cues\n", stderr); exit(1)
        }
        guard ScanFeedbackDisappearancePolicy.shouldExpire(scheduledGeneration: 12, currentGeneration: 12),
              !ScanFeedbackDisappearancePolicy.shouldExpire(scheduledGeneration: 11, currentGeneration: 12),
              ScanFeedbackTiming.recognizedLifetime <= 2.5,
              ScanFeedbackTiming.recognizedLifetime > ScanFeedbackTiming.resolvedLifetime else {
            fputs("self-test failed: scan feedback expiry generation\n", stderr); exit(1)
        }
        let stableAnchor = ScanFeedbackAnchor(
            literal: "GLINT-24",
            bounds: CGRect(x: 120.1, y: 340.1, width: 72.1, height: 18.1)
        )
        let reconstructedAnchor = ScanFeedbackAnchor(
            literal: "GLINT-24",
            bounds: CGRect(x: 120.2, y: 340.2, width: 72.2, height: 18.2)
        )
        let changedAnchor = ScanFeedbackAnchor(
            literal: "GLINT-25",
            bounds: CGRect(x: 120.1, y: 340.1, width: 72.1, height: 18.1)
        )
        let secondaryAnchor = ScanFeedbackAnchor(
            literal: "HAUSV-38",
            bounds: CGRect(x: 260, y: 280, width: 82, height: 18)
        )
        let recognizedPhase = ScanFeedbackPhase.recognized(
            anchors: [stableAnchor], selectedID: stableAnchor.id
        )
        let repeatedRecognized = ScanFeedbackPhase.recognized(
            anchors: [reconstructedAnchor], selectedID: reconstructedAnchor.id
        )
        let recognizedDecision = ScanFeedbackPresentationPolicy.decision(
            current: recognizedPhase, incoming: repeatedRecognized, generation: 20
        )
        let resolvedPhase = ScanFeedbackPhase.resolved(anchor: stableAnchor)
        let resolvedDecision = ScanFeedbackPresentationPolicy.decision(
            current: resolvedPhase,
            incoming: .resolved(anchor: reconstructedAnchor),
            generation: recognizedDecision.generation
        )
        let changedDecision = ScanFeedbackPresentationPolicy.decision(
            current: resolvedPhase,
            incoming: .resolved(anchor: changedAnchor),
            generation: resolvedDecision.generation
        )
        let activeOnly = LookupHighlightPolicy.visibleAnchors(
            [stableAnchor, secondaryAnchor], selected: secondaryAnchor, showAll: false
        )
        let allLookupAnchors = LookupHighlightPolicy.visibleAnchors(
            [stableAnchor, stableAnchor], selected: secondaryAnchor, showAll: true
        )
        let scannedSource = LookupSourceSnapshot(
            processIdentifier: 42,
            windowIdentifier: 7,
            windowBounds: CGRect(x: 10, y: 20, width: 900, height: 700),
            windowTitle: "NUNCID-52"
        )
        let movedSource = LookupSourceSnapshot(
            processIdentifier: 42,
            windowIdentifier: 7,
            windowBounds: CGRect(x: 11, y: 20, width: 900, height: 700),
            windowTitle: "NUNCID-52"
        )
        let midLockOn = FoundLockOnAnimationState.at(progress: 0.55)
        let settledLockOn = FoundLockOnAnimationState.at(progress: 1)
        let lookupDecision = ScanFeedbackPresentationPolicy.decision(
            current: .lookup(
                anchors: allLookupAnchors,
                selectedID: secondaryAnchor.id,
                celebratesFound: false
            ),
            incoming: .lookup(
                anchors: allLookupAnchors,
                selectedID: secondaryAnchor.id,
                celebratesFound: false
            ),
            generation: changedDecision.generation
        )
        let animatedLookupDecision = ScanFeedbackPresentationPolicy.decision(
            current: .lookup(
                anchors: allLookupAnchors,
                selectedID: secondaryAnchor.id,
                celebratesFound: true
            ),
            incoming: .lookup(
                anchors: allLookupAnchors,
                selectedID: secondaryAnchor.id,
                celebratesFound: false
            ),
            generation: lookupDecision.generation
        )
        guard stableAnchor.id == reconstructedAnchor.id,
              stableAnchor.id != changedAnchor.id,
              activeOnly == [secondaryAnchor],
              allLookupAnchors == [stableAnchor, secondaryAnchor],
              LookupHighlightVisibilityPolicy.shouldShow(
                popupVisible: true,
                mappedAnchorAvailable: true
              ),
              !LookupHighlightVisibilityPolicy.shouldShow(
                popupVisible: false,
                mappedAnchorAvailable: true
              ),
              LookupSourceLifecyclePolicy.remainsValid(
                scanned: scannedSource,
                current: scannedSource
              ),
              !LookupSourceLifecyclePolicy.remainsValid(
                scanned: scannedSource,
                current: movedSource
              ),
              midLockOn.sweepOpacity > 0,
              midLockOn.particleOpacity > 0,
              settledLockOn.sweep == 1,
              settledLockOn.sweepOpacity == 0,
              settledLockOn.confirmationOpacity == 0,
              settledLockOn.particleOpacity == 0,
              recognizedDecision == .init(action: .refreshExpiry, generation: 21),
              resolvedDecision == .init(action: .refreshExpiry, generation: 22),
              changedDecision == .init(action: .rebuild, generation: 23),
              lookupDecision == .init(action: .refreshExpiry, generation: 24),
              animatedLookupDecision == .init(action: .rebuild, generation: 25),
              ScanFeedbackStyleMetrics.foundAnimationDuration < 1,
              ScanFeedbackDisappearancePolicy.shouldExpire(
                scheduledGeneration: resolvedDecision.generation,
                currentGeneration: resolvedDecision.generation
              ),
              !ScanFeedbackDisappearancePolicy.shouldExpire(
                scheduledGeneration: recognizedDecision.generation,
                currentGeneration: resolvedDecision.generation
              ) else {
            fputs("self-test failed: idempotent scan feedback presentation\n", stderr); exit(1)
        }
        guard !ManualInspectionPolicy.shouldDismiss(distanceFromAnchor: 35, elapsed: 7.9),
              ManualInspectionPolicy.shouldDismiss(distanceFromAnchor: 37, elapsed: 1),
              ManualInspectionPolicy.shouldDismiss(distanceFromAnchor: 0, elapsed: 8) else {
            fputs("self-test failed: manual inspection lifetime policy\n", stderr); exit(1)
        }
        let hideNow = Date(timeIntervalSinceReferenceDate: 100)
        guard TemporaryOverlayLifetimePolicy.shouldScheduleHide(
            isVisible: true,
            isPinned: false,
            pointerInside: false,
            movedFromLastPosition: true,
            manualLifetimeExpired: false
        ), !TemporaryOverlayLifetimePolicy.shouldScheduleHide(
            isVisible: true,
            isPinned: false,
            pointerInside: true,
            movedFromLastPosition: true,
            manualLifetimeExpired: true
        ), !TemporaryOverlayLifetimePolicy.shouldScheduleHide(
            isVisible: true,
            isPinned: true,
            pointerInside: false,
            movedFromLastPosition: true,
            manualLifetimeExpired: true
        ), TemporaryOverlayLifetimePolicy.shouldHide(
            deadline: hideNow,
            now: hideNow.addingTimeInterval(TemporaryOverlayLifetimePolicy.exitGrace),
            pointerInside: false
        ), !TemporaryOverlayLifetimePolicy.shouldHide(
            deadline: hideNow,
            now: hideNow.addingTimeInterval(TemporaryOverlayLifetimePolicy.exitGrace),
            pointerInside: true
        ) else {
            fputs("self-test failed: pointer-safe temporary popup lifetime\n", stderr); exit(1)
        }
        guard ResolutionLookupPolicy.initialCount(total: 16) == 4,
              ResolutionLookupPolicy.initialCount(total: 2) == 2,
              ResolutionLookupPolicy.shouldLaunchNext(launched: 4, total: 16, resolvedCount: 2, maximumResults: 12),
              !ResolutionLookupPolicy.shouldLaunchNext(launched: 4, total: 16, resolvedCount: 12, maximumResults: 12),
              !ResolutionLookupPolicy.shouldLaunchNext(launched: 16, total: 16, resolvedCount: 0, maximumResults: 12) else {
            fputs("self-test failed: bounded lookup scheduling policy\n", stderr); exit(1)
        }
        let directPlan = DirectEntryResolutionPlanner.plan(
            project: "GLINT", key: "GLINT-42", trackers: [.ppm, .pma]
        )
        guard directPlan.proposals.map(\.spec) == [
            .issue(tracker: .ppm, key: "GLINT-42"),
            .issue(tracker: .pma, key: "GLINT-42")
        ], directPlan.learningDecision(for: directPlan.proposals[0]) == nil,
           directPlan.learningDecision(for: directPlan.proposals[0], userConfirmed: true)?.basis == .userConfirmed else {
            fputs("self-test failed: direct-entry confirmation learning plan\n", stderr); exit(1)
        }
        let presentation = PresentationPreferences(
            alternativePreviews: 5,
            textSize: .extraLarge,
            width: .wide,
            density: .detailed,
            surface: .solid
        )
        presentation.persist(defaults: defaults)
        guard PresentationPreferences.load(defaults: defaults) == presentation,
              presentation.circularAlternativeIndices(count: 4, selectedIndex: 3) == [0, 1, 2] else {
            fputs("self-test failed: ticket appearance persistence/navigation\n", stderr)
            exit(1)
        }
        var customPresentation = presentation
        customPresentation.width = .custom
        customPresentation.customWidth = 777
        customPresentation.customHeight = 333
        customPresentation.persist(defaults: defaults)
        let neighborRail = NeighborRailPolicy.indices(count: 7, selectedIndex: 3, visibleCount: 6)
        let customOverlay = OverlayMetrics.size(
            lines: [],
            sticky: true,
            preferences: customPresentation,
            visibleFrame: CGRect(x: 0, y: 0, width: 720, height: 300)
        )
        let popupPreferences = PopupInteractionPreferences(
            scrollModifier: .command,
            restorePinned: true,
            showAllDetectedIDsWhenPinned: true
        )
        popupPreferences.persist(defaults: defaults)
        let forwardGeneration = 1
        let reverseGeneration = 2
        let staleCompletedGeneration = TicketTitleSettlePolicy.completedGeneration(
            current: 0,
            callbackGeneration: forwardGeneration
        )
        let reverseCompletedGeneration = TicketTitleSettlePolicy.completedGeneration(
            current: staleCompletedGeneration,
            callbackGeneration: reverseGeneration
        )
        let alreadySettledGeneration = 7
        let nextResultSetFlightGeneration = TicketTitleSettlePolicy.nextGeneration(
            after: alreadySettledGeneration
        )
        let upwardRail = SpatialRailTransitionPolicy.boundaries(navigationDirection: 1)
        let downwardRail = SpatialRailTransitionPolicy.boundaries(navigationDirection: -1)
        guard PresentationPreferences.load(defaults: defaults) == customPresentation,
              customOverlay == CGSize(width: 704, height: 284),
              neighborRail.previous == [0, 1, 2],
              neighborRail.next == [4, 5, 6],
              TicketKeyMotionPolicy.style(reduceMotion: false) == .matchedFlight,
              TicketKeyMotionPolicy.style(reduceMotion: true) == .opacityOnly,
              TicketKeyMotionPolicy.titleSettleDelay >= 0.34,
              forwardGeneration == 1,
              reverseGeneration == 2,
              !TicketTitleSettlePolicy.isSettled(
                  navigationGeneration: reverseGeneration,
                  settledGeneration: staleCompletedGeneration,
                  reduceMotion: false
              ),
              TicketTitleSettlePolicy.isSettled(
                  navigationGeneration: reverseGeneration,
                  settledGeneration: reverseCompletedGeneration,
                  reduceMotion: false
              ),
              TicketTitleSettlePolicy.isSettled(
                  navigationGeneration: reverseGeneration,
                  settledGeneration: 0,
                  reduceMotion: true
              ),
              nextResultSetFlightGeneration == 8,
              !TicketTitleSettlePolicy.isSettled(
                  navigationGeneration: nextResultSetFlightGeneration,
                  settledGeneration: alreadySettledGeneration,
                  reduceMotion: false
              ),
              upwardRail.insertion == .bottom,
              upwardRail.removal == .top,
              downwardRail.insertion == .top,
              downwardRail.removal == .bottom,
              SpatialRailTransitionPolicy.directionLeadTime > 0,
              SpatialRailTransitionPolicy.directionLeadTime <= 1.0 / 60.0,
              PinnedHeaderLayoutPolicy.contextWidth(totalWidth: 420) == 100,
              PinnedHeaderLayoutPolicy.contextWidth(totalWidth: 590) == 176,
              PopupInteractionPreferences.load(defaults: defaults) == popupPreferences,
              PopupScrollModifier.option.matches([.option, .capsLock]),
              !PopupScrollModifier.option.matches([.option, .shift]) else {
            fputs("self-test failed: custom popup geometry, rail, and interaction preferences\n", stderr); exit(1)
        }
        let ppmDestination = TicketLine(key: "NUNCID-35", state: "done", title: "Link", source: "ppm").destinationURL
        let githubDestination = TicketLine(key: "#184", state: "open", title: "Link", source: "gh", metadata: "markus-barta/nuncid · pull request").destinationURL
        guard ppmDestination?.absoluteString == "https://pm.barta.cm/issues/NUNCID-35",
              githubDestination?.absoluteString == "https://github.com/markus-barta/nuncid/pull/184" else {
            fputs("self-test failed: source destination links\n", stderr); exit(1)
        }
        let naturalSingle = OverlayMetrics.size(
            lines: [TicketLine(key: "NUNCID-1", state: "open", title: "Short result", source: "ppm")],
            sticky: false,
            preferences: .defaults,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        guard naturalSingle.height < OverlaySizePolicy.minimum.height,
              OverlayMetrics.temporaryBodyHeight(totalHeight: naturalSingle.height) == naturalSingle.height - OverlayMetrics.outerPadding * 2 - 28 else {
            fputs("self-test failed: naturally measured popup height and temporary body budget\n", stderr); exit(1)
        }
        guard AppearanceResetPolicy.shouldKeepUndo(previous: presentation, current: .defaults),
              !AppearanceResetPolicy.shouldKeepUndo(previous: presentation, current: presentation),
              !AppearanceResetPolicy.shouldKeepUndo(previous: nil, current: .defaults) else {
            fputs("self-test failed: appearance reset undo lifecycle\n", stderr); exit(1)
        }
        let previewLines = (1...6).map {
            TicketLine(key: "GLINT-\($0)", state: "open", title: "Preview \($0)", source: "ppm", detail: "Detail")
        }
        let variedPrimaryLines = [
            TicketLine(key: "NUNCID-16", state: "done", title: "Short title", source: "ppm"),
            TicketLine(key: "HAUSV-38", state: "in-progress", title: "A much longer title that wraps and proves the primary card does not move while identities travel", source: "ppm", metadata: "ticket · high priority", detail: "Longer supporting detail occupies the stable slot without pushing either spatial rail.")
        ]
        let stablePrimary = OverlayMetrics.stablePrimaryHeight(
            lines: variedPrimaryLines,
            preferences: presentation,
            width: presentation.width.points
        )
        let individualPrimaryHeights = variedPrimaryLines.map({
            OverlayMetrics.primaryHeight(line: $0, preferences: presentation, width: presentation.width.points)
        })
        guard individualPrimaryHeights.allSatisfy({ stablePrimary >= $0 }),
              OverlayMetrics.stablePrimaryTitleHeight(
                  lines: variedPrimaryLines,
                  preferences: presentation,
                  width: presentation.width.points
              ) == variedPrimaryLines.map({
                  OverlayMetrics.primaryTitleHeight(
                      line: $0,
                      preferences: presentation,
                      width: presentation.width.points
                  )
              }).max() else {
            fputs("self-test failed: stable primary slot and ticket-key motion policy\n", stderr); exit(1)
        }
        var shortTemporaryPreferences = customPresentation
        shortTemporaryPreferences.alternativePreviews = 6
        shortTemporaryPreferences.customWidth = 420
        shortTemporaryPreferences.customHeight = 260
        let shortTemporarySize = OverlayMetrics.size(
            lines: previewLines,
            sticky: false,
            preferences: shortTemporaryPreferences,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let shortTemporaryNeighbors = OverlayMetrics.visibleAlternativeCount(
            lines: previewLines,
            preferences: shortTemporaryPreferences,
            width: shortTemporarySize.width,
            totalHeight: shortTemporarySize.height,
            sticky: false
        )
        guard shortTemporarySize == CGSize(width: 420, height: 260),
              shortTemporaryNeighbors < shortTemporaryPreferences.alternativePreviews else {
            fputs("self-test failed: short temporary card adaptive neighbor budget\n", stderr); exit(1)
        }
        let previewHeight = OverlayMetrics.preferredHeight(lines: previewLines, sticky: true, preferences: presentation)
        let previewScale = OverlayMetrics.previewScale(
            contentWidth: presentation.width.points,
            availableWidth: 556,
            contentHeight: previewHeight,
            maximumHeight: 300
        )
        var noAlternatives = presentation
        noAlternatives.alternativePreviews = 0
        guard presentation.width.points * previewScale <= 556.001,
              previewHeight * previewScale <= 300.001,
              previewScale > 0,
              noAlternatives.circularAlternativeIndices(count: 6, selectedIndex: 0).isEmpty,
              OverlayMetrics.preferredHeight(lines: previewLines, sticky: true, preferences: noAlternatives) < previewHeight else {
            fputs("self-test failed: bounded XL appearance preview\n", stderr)
            exit(1)
        }
        let constrainedOverlay = OverlayMetrics.size(
            lines: previewLines,
            sticky: true,
            preferences: presentation,
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 330)
        )
        let pinnedBody = OverlayMetrics.pinnedBodyHeight(totalHeight: constrainedOverlay.height)
        guard pinnedBody > 0,
              pinnedBody + OverlayMetrics.pinnedReservedChromeHeight <= constrainedOverlay.height + 0.001 else {
            fputs("self-test failed: footer-safe max-stress pinned layout\n", stderr); exit(1)
        }
        let shortStressLines = [
            TicketLine(
                key: "GLINT-24",
                state: "in-progress",
                title: "Make detailed ticket cards adapt precisely to long real-world titles without hiding alternatives",
                source: "ppm",
                metadata: "ticket · high priority · release 0.3",
                detail: "A deliberately long tracker detail verifies that the primary result remains legible while every alternative row is either fully visible or omitted from the rail."
            )
        ] + Array(previewLines.prefix(5))
        let shortVisibleFrame = CGRect(x: 0, y: 0, width: 900, height: 500)
        let shortOverlay = OverlayMetrics.size(
            lines: shortStressLines,
            sticky: true,
            preferences: presentation,
            visibleFrame: shortVisibleFrame
        )
        let shortAlternativeCount = OverlayMetrics.visibleAlternativeCount(
            lines: shortStressLines,
            preferences: presentation,
            width: shortOverlay.width,
            totalHeight: shortOverlay.height,
            sticky: true
        )
        let shortPrimaryHeight = OverlayMetrics.primaryHeight(
            line: shortStressLines[0],
            preferences: presentation,
            width: shortOverlay.width
        )
        let shortBodyBudget = OverlayMetrics.pinnedBodyHeight(totalHeight: shortOverlay.height)
        let shortUsedHeight = shortPrimaryHeight + OverlayMetrics.sectionSpacing +
            OverlayMetrics.alternativeBlockHeight(
                count: shortAlternativeCount,
                sticky: true,
                preferences: presentation
            )
        let shortNextHeight = shortPrimaryHeight + OverlayMetrics.sectionSpacing +
            OverlayMetrics.alternativeBlockHeight(
                count: shortAlternativeCount + 1,
                sticky: true,
                preferences: presentation
            )
        guard shortAlternativeCount > 0,
              shortAlternativeCount < presentation.alternativePreviews,
              shortPrimaryHeight <= shortBodyBudget,
              shortUsedHeight <= shortBodyBudget,
              shortNextHeight > shortBodyBudget else {
            fputs("self-test failed: short-display whole-row alternative budget\n", stderr); exit(1)
        }
        let negativeDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let negativeScreen = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        let syntheticCapture = CapturePlan(
            rect: CGRect(x: -1820, y: 100, width: 200, height: 50),
            displayBounds: negativeDisplay,
            screenFrame: negativeScreen
        )
        guard syntheticCapture.appKitRect(forQuartz: syntheticCapture.rect) == CGRect(x: -1820, y: 810, width: 200, height: 50),
              syntheticCapture.quartzRect(forVisionNormalized: CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)) == CGRect(x: -1770, y: 120, width: 100, height: 20) else {
            fputs("self-test failed: CapturePlan coordinate conversion\n", stderr); exit(1)
        }
        let feedbackScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        guard ScanFeedbackGeometry.panelFrame(
            around: CGRect(x: 200, y: 300, width: 80, height: 20),
            lastPoint: .zero,
            screenFrames: [],
            mainScreenFrame: nil
        ) == nil,
        let clampedFeedbackFrame = ScanFeedbackGeometry.panelFrame(
            around: CGRect(x: 9_000, y: 9_000, width: 80, height: 20),
            lastPoint: .zero,
            screenFrames: [feedbackScreen],
            mainScreenFrame: feedbackScreen
        ), feedbackScreen.intersects(clampedFeedbackFrame), !clampedFeedbackFrame.isEmpty else {
            fputs("self-test failed: safe scan-feedback screen fallback\n", stderr)
            exit(1)
        }
        let anchorBounds = CGRect(x: 120, y: 340, width: 72, height: 18)
        let fragment = RecognizedTextFragment(
            text: "Open GLINT-24 now",
            confidence: 0.98,
            normalizedBounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
            screenBounds: CGRect(x: 100, y: 330, width: 220, height: 28),
            spans: [RecognizedTextSpan(
                literal: "GLINT-24",
                utf16Range: NSRange(location: 5, length: 8),
                normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.15, height: 0.08),
                screenBounds: anchorBounds
            )]
        )
        let anchorInput = OCRContextInput(fragments: [
            OCRContextFragment(text: fragment.text, lineIndex: 0, order: 0, confidence: 0.98)
        ])
        guard let anchorToken = TokenParser.parse(anchorInput).first,
              ScanFeedbackAnchor(token: anchorToken, fragments: [fragment])?.bounds == anchorBounds else {
            fputs("self-test failed: token-anchored scan feedback\n", stderr)
            exit(1)
        }
        let collapsedLineRelationship = OCRVisualLayout.relationship(
            firstRegion: .init(x: 0.1, y: 0.8, width: 0.2, height: 0.05),
            firstLine: 4,
            secondRegion: .init(x: 0.1, y: 0.4, width: 0.2, height: 0.05),
            secondLine: 4
        )
        guard !collapsedLineRelationship.isSameVisualLine,
              collapsedLineRelationship.lineGap == 1 else {
            fputs("self-test failed: collapsed OCR line relationship\n", stderr); exit(1)
        }
        let denseInput = OCRContextInput(lines: [
            "Release 0.3.0 build 2026 08 29 GLINT-19 #184 PAI-843 999 1000"
        ])
        let denseTokens = TokenParser.parse(denseInput)
        let densePlan = EvidenceCandidatePlanner.plan(input: denseInput, context: context)
        let denseOrders = ScanAnchorPolicy.sourceOrders(tokens: denseTokens, plan: densePlan)
        let versionOrders = Set(denseTokens.compactMap { token -> Int? in
            if case .version = token.kind { return token.sourceOrder }
            return nil
        })
        guard denseOrders.count <= ScanAnchorPolicy.maximumAnchors,
              denseOrders.allSatisfy({ !versionOrders.contains($0) }),
              denseOrders.allSatisfy({ order in densePlan.proposals.contains(where: { $0.sourceOrder == order }) }) else {
            fputs("self-test failed: proposal-backed capped scan anchors\n", stderr); exit(1)
        }
        let historyProposal = CandidateProposal(
            spec: .issue(tracker: .ppm, key: "GLINT-24"), score: 100,
            reasons: [.init(code: "test", label: "test", weight: 100, strength: .strong)],
            sourceOrder: 0, inferredProject: "GLINT", learningEligibility: .userConfirmation
        )
        ResolutionHistoryStore.record(
            .init(proposal: historyProposal, basis: .userConfirmed),
            bundleIdentifier: "at.example.editor", defaults: defaults,
            now: Date(timeIntervalSince1970: 1_000)
        )
        var learnedContext = ResolutionContext.load(defaults: defaults)
        learnedContext.saw(project: "GLINT", on: .ppm, defaults: defaults)
        guard ResolutionHistoryStore.load(defaults: defaults).entries.count == 1,
              defaults.string(forKey: "lastPPMProject") == "GLINT" else {
            fputs("self-test failed: learned context round-trip\n", stderr); exit(1)
        }
        LearnedContextStore.clear(defaults: defaults)
        guard ResolutionHistoryStore.load(defaults: defaults).entries.isEmpty,
              defaults.object(forKey: "lastSeenTracker") == nil,
              defaults.object(forKey: "lastPPMProject") == nil,
              defaults.object(forKey: "lastPMAProject") == nil,
              defaults.object(forKey: "pinnedProject") == nil,
              defaults.object(forKey: "pinnedNumber") == nil else {
            fputs("self-test failed: learned context clear\n", stderr); exit(1)
        }
        let resolverFailures = ResolverDeterministicChecks.run()
        guard resolverFailures.isEmpty else {
            fputs("self-test failed: evidence resolver: \(resolverFailures.joined(separator: ", "))\n", stderr)
            exit(1)
        }
        let cancellationFinished = DispatchSemaphore(value: 0)
        let cancellationResult = SelfTestAsyncResult()
        Task.detached {
            let startedAt = Date()
            let processTask = Task {
                await TicketResolver.runProcessForTesting(
                    URL(fileURLWithPath: "/bin/sleep"), ["5"]
                )
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            processTask.cancel()
            let output = await processTask.value
            cancellationResult.set(output == nil && Date().timeIntervalSince(startedAt) < 2)
            cancellationFinished.signal()
        }
        guard cancellationFinished.wait(timeout: .now() + 3) == .success,
              cancellationResult.get() else {
            fputs("self-test failed: subprocess cancellation propagation\n", stderr); exit(1)
        }
        print("Nuncid self-tests passed")
        exit(0)
    }
}
