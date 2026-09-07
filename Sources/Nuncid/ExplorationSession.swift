import AppKit
import CoreGraphics
import SwiftUI

private struct ExplorationJob {
    let id: String
    let literal: String
    let primary: [CandidateSpec]
    let fallback: [CandidateSpec]
    let contextReason: String
    var outcome: ExplorationOutcome = .queued
    var lines: [TicketLine] = []
    var resolvedAt: Date?
}

private struct ExplorationOccurrence {
    let jobID: String
    let anchor: ScanFeedbackAnchor
    let confidence: Double
}

private final class ExplorationMarkerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ExplorationMarkerView: NSView {
    var markers: [(CGRect, ExplorationOutcome, Bool)] = [] { didSet { needsDisplay = true } }
    var appearancePreferences = MarkerAppearancePreferences() {
        didSet { if oldValue != appearancePreferences { needsDisplay = true } }
    }
    override func draw(_ dirtyRect: NSRect) {
        for (bounds, outcome, selected) in markers {
            let state = outcome.markerState
            MarkerRenderer.draw(bounds: bounds, state: state, selected: selected,
                                style: appearancePreferences[state])
        }
    }
}

/// Owns one explicit exploration session. Geometry and lookup lifetimes are
/// separate: scrolling discards screen coordinates, not useful resolver work.
@MainActor final class ExplorationSession {
    private let ocr: ScreenOCR
    private let resolver: TicketResolver
    private let planner: TicketEvidencePlanner
    private let overlay: OverlayController
    var onStateChange: ((Bool, Bool, String) -> Void)?
    var onCloseRequested: (() -> Void)?
    private(set) var isActive = false
    private var sessionGeneration = 0
    private var geometryGeneration = 0
    private var jobs: [String: ExplorationJob] = [:]
    private var occurrences: [ExplorationOccurrence] = []
    private var previousNavigationIDs: [String] = []
    private var workers: [String: Task<Void, Never>] = [:]
    private var discovery: Task<Void, Never>?
    private var tiles: [CGRect] = []
    private var focus = CGPoint.zero
    private var screenFrame = CGRect.zero
    private var source: LookupSourceSnapshot?
    private var lastValidation = Date.distantPast
    private var refreshAfter: Date?
    private var selected: String?
    private var selectedBounds: CGRect?
    private var promoted: String?
    private var hover = ExplorationHover()
    private var monitor: Any?
    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var markerAppearanceObserver: NSObjectProtocol?
    private let markerPanel: ExplorationMarkerPanel
    private let markerView = ExplorationMarkerView()

    init(ocr: ScreenOCR, resolver: TicketResolver, planner: TicketEvidencePlanner, overlay: OverlayController) {
        self.ocr = ocr; self.resolver = resolver; self.planner = planner; self.overlay = overlay
        markerPanel = ExplorationMarkerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        markerPanel.level = .floating
        markerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        markerPanel.isOpaque = false; markerPanel.backgroundColor = .clear
        markerPanel.hasShadow = false; markerPanel.ignoresMouseEvents = true
        markerPanel.hidesOnDeactivate = false; markerPanel.sharingType = .none
#if DEBUG
        if CommandLine.arguments.contains("--capture-live") { markerPanel.sharingType = .readOnly }
#endif
        markerPanel.contentView = markerView
    }

    func start(at point: CGPoint) {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              Self.displayIsAwake(screen) else { return }
        focus = point
        if isActive, screen.frame == screenFrame, refreshAfter == nil {
            tiles.sort { ExplorationPolicy.distance($0, to: point) < ExplorationPolicy.distance($1, to: point) }
            promoted = occurrence(at: point)?.jobID
            if let promoted { select(promoted, retry: false, near: point) }
            pump()
            return
        }
        if !isActive {
            sessionGeneration += 1
            isActive = true
            installObservers()
        }
        screenFrame = screen.frame
        refresh()
    }

    func end() {
        guard isActive else { return }
        isActive = false; sessionGeneration += 1; geometryGeneration += 1
        discovery?.cancel(); discovery = nil
        workers.values.forEach { $0.cancel() }; workers.removeAll()
        jobs.removeAll(); occurrences.removeAll(); previousNavigationIDs.removeAll(); tiles.removeAll()
        refreshAfter = nil; selected = nil; selectedBounds = nil; promoted = nil
        hover = ExplorationHover()
        markerPanel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil; localMonitor = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let markerAppearanceObserver { NotificationCenter.default.removeObserver(markerAppearanceObserver) }
        markerAppearanceObserver = nil
        onStateChange?(false, false, "Ready")
    }

    func externalContentMayMove() {
        if screenFrame.contains(NSEvent.mouseLocation) { invalidateGeometry() }
    }

    func invalidateGeometry() {
        guard isActive else { return }
        geometryGeneration += 1
        discovery?.cancel(); discovery = nil
        if !occurrences.isEmpty { previousNavigationIDs = visibleJobIDs() }
        occurrences.removeAll(); tiles.removeAll(); hover = ExplorationHover()
        markerPanel.orderOut(nil)
        refreshAfter = Date().addingTimeInterval(ExplorationPolicy.settleDuration)
    }

    func tick() {
        guard isActive else { return }
        guard CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }),
              Self.displayIsAwake(screen) else { end(); overlay.hide(); return }
        let now = Date()
        if now.timeIntervalSince(lastValidation) >= LookupSourceLifecyclePolicy.validationInterval {
            lastValidation = now
            let current = LookupSourceSnapshot.capture()
            // Focusing our card does not move its source. External activation does.
            let sameWindow = source?.windowIdentifier != nil && current?.windowIdentifier == source?.windowIdentifier
            let sourceDisappeared = current?.processIdentifier == source?.processIdentifier && current?.windowIdentifier == nil
            if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               sourceIsOnDisplay(current) || sameWindow || sourceDisappeared, current != source {
                source = current
                invalidateGeometry()
            }
        }
        if let deadline = refreshAfter {
            if now >= deadline { refresh() }
            return
        }
        let point = NSEvent.mouseLocation
        let candidate = occurrence(at: point)
        if candidate?.jobID != hover.candidate {
            promoted = candidate?.jobID
            pump()
        }
        let preferences = ExplorationPreferences.load()
        if let id = hover.update(candidate: candidate?.jobID, now: now, delay: Double(preferences.hoverMilliseconds) / 1_000) {
            selectedBounds = candidate?.anchor.bounds
            select(id, retry: false, near: point)
        }
        renderMarkers()
        pump()
    }

    /// Returns false only outside a session so ordinary pinned navigation can
    /// retain its existing behavior. Unknown outcomes are normal-wheel entries.
    func navigate(_ direction: Int, includeMisses: Bool) -> Bool {
        guard isActive else { return false }
        let ids = navigationIDs()
        let eligible = Set(ids.filter { jobs[$0]?.outcome.isNavigable(includeMisses: includeMisses) == true })
        guard let next = ExplorationPolicy.next(in: ids, selected: selected, direction: direction, eligible: eligible) else { return true }
        let generation = sessionGeneration
        let previous = selected
        overlay.prepareExplorationNavigation(direction)
        DispatchQueue.main.asyncAfter(deadline: .now() + SpatialRailTransitionPolicy.directionLeadTime) { [weak self] in
            guard let self, isActive, generation == sessionGeneration, selected == previous else { return }
            selectedBounds = occurrences.first { $0.jobID == next }?.anchor.bounds
            select(next, retry: includeMisses, near: focus)
        }
        return true
    }

    private func select(_ id: String, retry: Bool, near point: CGPoint) {
        guard var job = jobs[id] else { return }
        selected = id; promoted = id
        if let spec = job.primary.first, case .workflowRun = spec,
           job.outcome == .matched, let resolvedAt = job.resolvedAt,
           Date().timeIntervalSince(resolvedAt) >= GitHubRunPreview.cacheLifetime(for: spec, line: job.lines.first) {
            // Refresh stale run summaries on an explicit revisit, not an OCR
            // timer or background log/artifact poll.
            job.outcome = .queued; job.lines = []; jobs[id] = job
        }
        if retry, job.outcome == .missed {
            job.outcome = .queued
            jobs[id] = job
            // Bypass only these negative entries, never the entire cache.
            let specs = job.primary + job.fallback
            let generation = sessionGeneration
            workers[id] = Task { [weak self] in
                guard let self else { return }
                await resolver.forgetMisses(for: specs)
                guard !Task.isCancelled, isActive, generation == sessionGeneration else { return }
                workers[id] = nil
                pump()
            }
        }
        present(job, near: point)
        renderMarkers(); pump()
    }

    private func present(_ job: ExplorationJob, near point: CGPoint) {
        let status: String?
        switch job.outcome {
        case .queued, .resolving:
            status = job.primary.isEmpty ? "\(job.literal) · \(job.contextReason). Add context or paste a complete reference." : "Checking \(job.literal)…"
        case .missed: status = "No match for \(job.literal) · Option + scroll to retry"
        case .matched: status = nil
        }
        var lines = job.lines
        if let current = job.lines.first {
            let matches = HoverResultPolicy.visible(from: navigationIDs().flatMap { jobs[$0]?.lines ?? [] } + job.lines, limit: ExplorationPolicy.maximumCandidates)
            if matches.count <= HoverResultPolicy.maximumResults { lines = matches }
            else if let index = matches.firstIndex(where: { $0.id == current.id }) {
                let count = HoverResultPolicy.maximumResults
                lines = (0..<count).map { matches[(index - count / 2 + $0 + matches.count) % matches.count] }
            }
        }
        overlay.showExploration(lines, selecting: job.lines.first?.id, status: status, near: point)
        onStateChange?(true, job.outcome == .matched, status ?? job.lines.first?.title ?? "Exploring")
    }

    private func navigationIDs() -> [String] {
        let visible = visibleJobIDs()
        if !previousNavigationIDs.isEmpty, visible.isEmpty || discovery != nil { return previousNavigationIDs }
        return visible
    }

    private func visibleJobIDs() -> [String] {
        var seen = Set<String>()
        return occurrences.sorted {
            let lhs = ExplorationPolicy.distance($0.anchor.bounds, to: focus)
            let rhs = ExplorationPolicy.distance($1.anchor.bounds, to: focus)
            return lhs == rhs ? $0.jobID < $1.jobID : lhs < rhs
        }.compactMap { seen.insert($0.jobID).inserted ? $0.jobID : nil }
    }

    private func pump() {
        guard isActive else { return }
        let limit = ExplorationPreferences.load().parallelLookups
        var pending = visibleJobIDs().filter { jobs[$0]?.outcome == .queued && jobs[$0]?.primary.isEmpty == false }
        if let promoted, jobs[promoted]?.outcome == .queued, jobs[promoted]?.primary.isEmpty == false { pending.insert(promoted, at: 0) }
        for id in ExplorationPolicy.dispatch(pending: pending, running: Set(workers.keys), promoted: promoted, limit: limit) {
            guard let job = jobs[id] else { continue }
            jobs[id]?.outcome = .resolving
            let generation = sessionGeneration
            workers[id] = Task { [weak self] in
                guard let self else { return }
                var lines: [TicketLine] = []
                for phase in [job.primary, job.fallback] {
                    for spec in phase {
                        guard !Task.isCancelled else { return }
                        if let line = await resolver.resolve(spec) {
                            lines.append(TicketLine(key: line.key, state: line.state, title: line.title,
                                source: line.source, metadata: [line.metadata, "Matched: \(job.contextReason)"].filter { !$0.isEmpty }.joined(separator: " · "),
                                detail: line.detail, destination: line.destination, identity: line.id))
                            break
                        }
                    }
                    if !lines.isEmpty { break }
                }
                guard !Task.isCancelled, isActive, generation == sessionGeneration else { return }
                jobs[id]?.lines = lines
                jobs[id]?.resolvedAt = Date()
                jobs[id]?.outcome = lines.isEmpty ? .missed : .matched
                workers[id] = nil
                if let selected, let completed = jobs[selected] { present(completed, near: focus) }
                renderMarkers(); pump()
            }
        }
    }

    private func refresh() {
        guard isActive, let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else { end(); return }
        geometryGeneration += 1
        discovery?.cancel()
        if !occurrences.isEmpty { previousNavigationIDs = visibleJobIDs() }
        occurrences.removeAll(); markerPanel.orderOut(nil); refreshAfter = nil
        // Remove unreachable cache records to keep long sessions bounded. The
        // resolver still holds its normal TTL cache; active/selected jobs survive.
        if jobs.count >= ExplorationPolicy.maximumCandidates {
            jobs = jobs.filter { workers[$0.key] != nil || $0.key == selected }
        }
        let current = LookupSourceSnapshot.capture()
        if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier, sourceIsOnDisplay(current) { source = current }
        let content = ExplorationPolicy.contentFrame(screen: screen.frame, visible: screen.visibleFrame,
            menuHeight: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
        tiles = ExplorationPolicy.tiles(in: content, around: focus)
        let generation = geometryGeneration
        onStateChange?(true, selected.flatMap { jobs[$0]?.outcome } == .matched, "Exploring outward from pointer…")
        discovery = Task { [weak self] in
            guard let self else { return }
            var contextReads = Set<String>()
            while !tiles.isEmpty {
                guard !Task.isCancelled, isActive, generation == geometryGeneration else { return }
                let tile = tiles.removeFirst()
                guard let capture = CapturePlan.around(CGPoint(x: tile.midX, y: tile.midY), size: tile.size) else { continue }
                let windows = ScreenContextGeometry.windows(for: capture)
                let recognized = await ocr.recognizeFragments(plan: capture)
                guard !Task.isCancelled, generation == geometryGeneration else { return }
                let fragments = recognized.filter { !self.overOwnWindow($0.screenBounds) && ScreenContextGeometry.owner(of: $0.screenBounds, windows: windows) != nil }
                let captureBounds = capture.appKitRect(forQuartz: capture.rect)
                let input = OCRContextInput(fragments: fragments.enumerated().map { index, fragment in
                    let edgeMargin = max(3, fragment.screenBounds.width / CGFloat(max(1, fragment.text.count)))
                    return OCRContextFragment(text: fragment.text, lineIndex: index, order: index,
                        confidence: Double(fragment.confidence),
                        region: OCRNormalizedRegion(x: fragment.normalizedBounds.minX, y: fragment.normalizedBounds.minY, width: fragment.normalizedBounds.width, height: fragment.normalizedBounds.height),
                        contextGroup: ScreenContextGeometry.owner(of: fragment.screenBounds, windows: windows),
                        startClipped: fragment.screenBounds.minX - captureBounds.minX < edgeMargin,
                        endClipped: captureBounds.maxX - fragment.screenBounds.maxX < edgeMargin)
                })
                let references = await planner.classifyScreen(input)
                guard !Task.isCancelled, generation == geometryGeneration else { return }
                for reference in references where reference.isVisibleCandidate {
                    let token = reference.token
                    guard let anchor = ScanFeedbackAnchor(token: token, fragments: fragments), !overOwnWindow(anchor.bounds),
                          ScreenContextGeometry.isCompleteIdentifier(anchor.bounds, in: capture.appKitRect(forQuartz: capture.rect)) else { continue }
                    // Semantic identity, not literal equality: PR42 and run42 in
                    // different repositories must never share a resolution job.
                    let primary = reference.spec.map { [$0] } ?? []
                    if primary.isEmpty, reference.category != .unknown, contextReads.count < 8 {
                        let contextKey = "\(reference.category.rawValue):\(token.raw):\(Int(anchor.bounds.midX / 20)):\(Int(anchor.bounds.midY / 20))"
                        if contextReads.insert(contextKey).inserted {
                            // A command may be wider than a discovery tile. One
                            // bounded horizontal context read can recover its
                            // complete --repo value; never guess a cropped scope.
                            let wider = CGRect(x: anchor.bounds.midX - 500, y: anchor.bounds.midY - 120,
                                               width: 1_000, height: 240).intersection(content)
                            if wider.width > 20, wider.height > 20 { tiles.insert(wider, at: 0) }
                        }
                    }
                    let id = reference.spec?.cacheKey ?? "unresolved:\(reference.category.rawValue):\(anchor.id)"
                    if jobs[id] == nil {
                        guard jobs.count < ExplorationPolicy.maximumCandidates else { continue }
                        jobs[id] = ExplorationJob(id: id, literal: token.raw, primary: primary, fallback: [], contextReason: reference.reason)
                    }
                    let candidate = ExplorationOccurrence(jobID: id, anchor: anchor, confidence: token.confidence ?? 0)
                    if let index = occurrences.firstIndex(where: { ExplorationPolicy.sameOccurrence($0.anchor.bounds, anchor.bounds) }) {
                        // Overlapping tiles may OCR one glyph differently. Keep
                        // one marker, preferring a verified result then confidence.
                        let previous = occurrences[index]
                        let verified = jobs[previous.jobID]?.outcome == .matched
                        let strongerScope = jobs[previous.jobID]?.primary.isEmpty == true && !primary.isEmpty
                        if strongerScope || (!verified && candidate.confidence > previous.confidence) {
                            occurrences[index] = candidate
                            if selected == previous.jobID { selected = id }
                        }
                    } else { occurrences.append(candidate) }
                }
                renderMarkers(); pump()
                if selected == nil, let nearest = occurrence(at: focus) ?? occurrences.min(by: { ExplorationPolicy.distance($0.anchor.bounds, to: self.focus) < ExplorationPolicy.distance($1.anchor.bounds, to: self.focus) }) {
                    selectedBounds = nearest.anchor.bounds
                    select(nearest.jobID, retry: false, near: focus)
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            discovery = nil
            previousNavigationIDs = visibleJobIDs()
            if let selected, let current = jobs[selected] { present(current, near: focus) }
            if occurrences.isEmpty {
                onStateChange?(true, false, "No visible ticket IDs · Esc to end")
                if !overlay.isVisible { overlay.showExploration([], status: "No visible ticket IDs · Esc to end", near: focus) }
            }
        }
    }

    private func occurrence(at point: CGPoint) -> ExplorationOccurrence? {
        guard !overOwnWindow(CGRect(x: point.x, y: point.y, width: 1, height: 1)) else { return nil }
        return occurrences.filter { $0.anchor.bounds.insetBy(dx: -5, dy: -4).contains(point) }.min {
            ExplorationPolicy.distance($0.anchor.bounds, to: point) < ExplorationPolicy.distance($1.anchor.bounds, to: point)
        }
    }

    private static func displayIsAwake(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        let id = CGDirectDisplayID(number.uint32Value)
        return CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0
    }

    private func sourceIsOnDisplay(_ snapshot: LookupSourceSnapshot?) -> Bool {
        guard let bounds = snapshot?.windowBounds, let plan = CapturePlan.around(focus) else { return false }
        return plan.appKitRect(forQuartz: bounds).intersects(screenFrame)
    }

    private func overOwnWindow(_ rect: CGRect) -> Bool {
        NSApp.windows.contains { $0 !== markerPanel && !$0.ignoresMouseEvents && $0.isVisible && $0.frame.intersects(rect) }
    }

    private func renderMarkers() {
        guard isActive, refreshAfter == nil, !occurrences.isEmpty else { markerPanel.orderOut(nil); return }
        markerPanel.setFrame(screenFrame, display: false)
        let selectedOccurrence = occurrences.filter { $0.jobID == selected }.min {
            ExplorationPolicy.distance($0.anchor.bounds, to: selectedBounds.map { CGPoint(x: $0.midX, y: $0.midY) } ?? focus) < ExplorationPolicy.distance($1.anchor.bounds, to: selectedBounds.map { CGPoint(x: $0.midX, y: $0.midY) } ?? focus)
        }
        markerView.markers = occurrences.compactMap { occurrence in
            guard let job = jobs[occurrence.jobID], !overOwnWindow(occurrence.anchor.bounds) else { return nil }
            return (occurrence.anchor.bounds.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY), job.outcome, occurrence.anchor.id == selectedOccurrence?.anchor.id && overlay.isVisible)
        }
        markerPanel.orderFrontRegardless()
    }

#if DEBUG
    func debugSnapshot() -> [String: Any] {
        ["active": isActive, "geometryGeneration": geometryGeneration,
         "remainingTiles": tiles.count, "workers": workers.count,
         "cardVisible": overlay.isVisible, "opacity": overlay.debugOpacity, "scrollPresentation": overlay.debugScrollPresentation, "selected": selected.flatMap { jobs[$0]?.literal } ?? "",
         "candidates": occurrences.map { occurrence -> [String: Any] in
             let job = jobs[occurrence.jobID]!
             return ["literal": job.literal, "outcome": String(describing: job.outcome),
                     "x": occurrence.anchor.bounds.midX, "y": occurrence.anchor.bounds.midY]
         }]
    }
#endif

    private func installObservers() {
        markerView.appearancePreferences = MarkerAppearancePreferences.load()
        markerAppearanceObserver = NotificationCenter.default.addObserver(forName: .nuncidMarkerAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                // Presentation-only: never invalidate OCR geometry or relaunch a lookup.
                self.markerView.appearancePreferences = MarkerAppearancePreferences.load()
            }
        }
        // Passive event observation; never inspect keystroke text or swallow
        // events belonging to the source app. Global key observation may be
        // unavailable without existing Accessibility permission.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return }
            // The popup's monitor owns navigation-before-invalidation when it
            // is visible. Handling the same scroll twice would erase its queue.
            if event.type == .scrollWheel, overlay.isVisible { return }
            if event.type == .keyDown, event.keyCode == 53 { onCloseRequested?(); return }
            guard screenFrame.contains(NSEvent.mouseLocation) else { return }
            invalidateGeometry()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isActive, event.keyCode == 53 else { return event }
            onCloseRequested?(); return nil
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidateGeometry() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end(); self?.overlay.hide() }
        })
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.end(); self?.overlay.hide() }
        }
    }
}

#if DEBUG
private struct ExplorationMarkerSample: NSViewRepresentable {
    let literal: String
    let outcome: ExplorationOutcome
    func makeNSView(context: Context) -> NSView {
        let view = ExplorationMarkerView(frame: CGRect(x: 0, y: 0, width: 225, height: 75))
        let label = NSTextField(labelWithString: literal)
        label.font = .monospacedSystemFont(ofSize: 21, weight: .medium)
        label.sizeToFit()
        label.setFrameOrigin(CGPoint(x: (225 - label.frame.width) / 2, y: (75 - label.frame.height) / 2))
        view.addSubview(label)
        view.markers = [(label.frame, outcome, outcome == .matched)]
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct ExplorationReleaseProbe: View {
    static let canvasSize = CGSize(width: 1160, height: 560)
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Explore at your own pace.").font(.system(size: 40, weight: .bold))
            Text("Three quiet states. No badges. Configure every color and opacity in Detection Frames.").font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 22) {
                sample("NUNCID-63", .queued, "Unchecked / checking", "Gray dashes · 70% outline")
                sample("999999", .missed, "No match", "Dark gray · 50% diagonal")
                sample("NUNCID-65", .matched, "Matched", "Green · 10% fill")
            }
            Divider()
            Text("Scroll through matches and pending IDs. Hold Option to include misses.").font(.headline)
            Text("Source scrolling refreshes marker positions—not your card or resolved cache. Close the card or press Escape to end exploration.").font(.body).foregroundStyle(.secondary)
            Spacer()
            Text("Nuncid \(NuncidBrand.version) · Local OCR · Read-only lookups").font(.caption).foregroundStyle(.secondary)
        }
        .padding(44)
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func sample(_ literal: String, _ outcome: ExplorationOutcome, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ExplorationMarkerSample(literal: literal, outcome: outcome).frame(width: 225, height: 75)
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
