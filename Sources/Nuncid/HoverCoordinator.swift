import AppKit
import CoreGraphics
import Foundation

enum QueuedScanLifecyclePolicy {
    static func shouldLaunch(
        queuedGeneration: Int,
        currentGeneration: Int,
        completedGeneration: Int
    ) -> Bool {
        queuedGeneration == currentGeneration && queuedGeneration != completedGeneration
    }

    static func shouldRetargetAfterPointerMovement(source: ScanInvocationSource) -> Bool {
        source == .explicitCommand
    }
}

enum ScanInvocationSource: Equatable {
    case explicitCommand
    case menuTarget
    case automaticHover
}

enum ScanCuePolicy {
    static func showsInvoked(for source: ScanInvocationSource) -> Bool {
        source != .automaticHover
    }

    static func terminal(
        for source: ScanInvocationSource,
        hasResolvedResult: Bool
    ) -> ScanTerminalFeedback {
        // Successful scans transition directly from recognized candidates to
        // the persistent lock-on. A second terminal panel would be replaced
        // in the same run-loop turn and never become visible.
        if hasResolvedResult { return .none }
        return source != .automaticHover ? .noMatch : .none
    }
}

enum DirectEntryResolutionPlanner {
    static func plan(project: String, key: String, trackers: [Tracker]) -> ResolutionPlan {
        ResolutionPlan(proposals: trackers.enumerated().map { index, tracker in
            CandidateProposal(
                spec: .issue(tracker: tracker, key: key),
                score: 1_000 - index,
                reasons: [ResolutionReason(
                    code: "pinned-direct-entry",
                    label: "entered in pinned card",
                    weight: 1_000 - index,
                    strength: .strong
                )],
                sourceOrder: index,
                inferredProject: project,
                learningEligibility: .userConfirmation
            )
        })
    }
}

enum PinnedScanOwnershipPolicy {
    static func shouldInvalidateForInput(alreadyClaimed: Bool) -> Bool {
        !alreadyClaimed
    }

    static func permitsCompletion(
        startedScanGeneration: Int,
        currentScanGeneration: Int,
        startedDirectGeneration: Int,
        currentDirectGeneration: Int,
        startedEditGeneration: Int,
        currentEditGeneration: Int
    ) -> Bool {
        startedScanGeneration == currentScanGeneration &&
            startedDirectGeneration == currentDirectGeneration &&
            startedEditGeneration == currentEditGeneration
    }
}

struct LookupSourceSnapshot: Equatable {
    let processIdentifier: pid_t
    let windowIdentifier: CGWindowID?
    let windowBounds: CGRect?
    let windowTitle: String?

    static func capture() -> LookupSourceSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let processIdentifier = application.processIdentifier
        let window = windowInfo(for: processIdentifier)
        return LookupSourceSnapshot(
            processIdentifier: processIdentifier,
            windowIdentifier: (window?[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            windowBounds: window.flatMap(windowBounds(from:)),
            windowTitle: (window?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func windowInfo(for processIdentifier: pid_t) -> [String: Any]? {
        (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]])?.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    private static func windowBounds(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? NSNumber,
              let y = bounds["Y"] as? NSNumber,
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber else { return nil }
        return CGRect(
            x: x.doubleValue,
            y: y.doubleValue,
            width: width.doubleValue,
            height: height.doubleValue
        )
    }
}

enum LookupSourceLifecyclePolicy {
    static let validationInterval: TimeInterval = 0.25

    static func remainsValid(
        scanned: LookupSourceSnapshot?,
        current: LookupSourceSnapshot?
    ) -> Bool {
        guard let scanned else { return false }
        return scanned == current
    }
}

enum LookupHighlightVisibilityPolicy {
    static func shouldShow(popupVisible: Bool, mappedAnchorAvailable: Bool) -> Bool {
        popupVisible && mappedAnchorAvailable
    }
}

@MainActor final class HoverCoordinator {
    private enum Presentation { case temporary, pinned }

    private weak var appState: AppState?
    private let ocr = ScreenOCR()
    private let resolver = TicketResolver()
    private let evidencePlanner = TicketEvidencePlanner()
    private let scanFeedback = ScanFeedbackController()
    private let overlay: OverlayController
    private lazy var exploration = ExplorationSession(ocr: ocr, resolver: resolver, planner: evidencePlanner, overlay: overlay)
    private var detection = DetectionMode()
    private var detectionOrigin = NSEvent.mouseLocation
    private var timer: Timer?
    private var lastPosition = NSEvent.mouseLocation
    private var stableSince = Date()
    private var hoverScannedPosition: CGPoint?
    private var isScanning = false
    private var activeScanTask: Task<Void, Never>?
    private var lastPermissionPollAt = Date.distantPast
    private var scanGeneration = 0
    private var observedActivationPreferences: ActivationPreferences
    private var editState = PinnedEditState()
    private var editTask: Task<Void, Never>?
    private var directGeneration = 0
    private var pinnedEditGeneration = 0
    private var pinnedInputClaimedCurrentScan = false
    private struct PendingManualScan {
        let position: CGPoint
        let presentation: Presentation
        let generation: Int
        let source: ScanInvocationSource
        let invokedFeedbackShown: Bool
    }
    private var pendingManualScan: PendingManualScan?
    private var menuTargetSelection: MenuBarTargetSelection?
    private var menuTargetClickMonitor: Any?
    private var menuTargetGeneration = 0
    private struct ManualInspectionState {
        let anchor: CGPoint
        let startedAt: Date
    }
    private var manualInspection: ManualInspectionState?
    private var temporaryHideDeadline: Date?
    private var detectedAnchors: [ScanFeedbackAnchor] = []
    private var lookupAnchorByLineID: [String: ScanFeedbackAnchor] = [:]
    private var lookupSourceSnapshot: LookupSourceSnapshot?
    private var lastLookupSourceValidationAt = Date.distantPast

    init(appState: AppState) {
        self.appState = appState
        observedActivationPreferences = appState.activationPreferences
#if DEBUG
        overlay = OverlayController(allowsCapture: CommandLine.arguments.contains("--capture-live"))
#else
        overlay = OverlayController()
#endif
        overlay.onCycleProject = { [weak self] direction in self?.cycleProject(direction) }
        overlay.onClose = { [weak self] in self?.closePinned() }
        overlay.onInput = { [weak self] event in self?.handleInput(event) }
        overlay.onSelectionChange = { [weak self] line in
            self?.syncSelectionContext()
            self?.refreshLookupHighlight(selecting: line)
        }
        overlay.onExternalContentMayMove = { [weak self] in
            self?.invalidateLookupSource()
            self?.exploration.externalContentMayMove()
        }
        overlay.onExploreNavigation = { [weak self] direction, includeMisses in
            guard let self else { return false }
            directGeneration += 1; resetEditing()
            return exploration.navigate(direction, includeMisses: includeMisses)
        }
        exploration.onSelectionClaimed = { [weak self] in
            guard let self else { return }
            directGeneration += 1; resetEditing()
        }
        exploration.onPauseRequested = { [weak self] in self?.publishDetectionState(activity: "Detection paused · Waiting for capture access/display") }
        exploration.onStateChange = { [weak self] _, found, activity in
            self?.publishDetectionState(found: found, activity: activity)
        }
        overlay.onTogglePin = { [weak self] in self?.togglePinFromOverlay() }
        overlay.onPinStateChange = { [weak self] pinned in
            guard let self, var preferences = self.appState?.popupInteractionPreferences,
                  preferences.restorePinned != pinned else { return }
            preferences.restorePinned = pinned
            self.appState?.popupInteractionPreferences = preferences
        }
        overlay.onPresentationPreferencesChange = { [weak self] preferences in
            guard let self, self.appState?.presentationPreferences != preferences else { return }
            self.appState?.presentationPreferences = preferences
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if NuncidWindowPlacement.probeScreen != nil { return }
#endif
            self.overlay.restorePinnedIfNeeded(shortcutLabel: self.pinShortcutLabel)
        }
    }

#if DEBUG
    func explorationDebugSnapshot() -> [String: Any] {
        var snapshot = exploration.debugSnapshot()
        snapshot["detectionEnabled"] = detection.enabled
        snapshot["waitingForTarget"] = menuTargetSelection != nil
        snapshot["pinned"] = overlay.isSticky
        return snapshot
    }
#endif

    func endExploration() { closePinned() }

    func escapeInspection() {
        if editState.hasInput {
            if let project = editState.projectBeforeQuery { currentProject = project }
            directGeneration += 1; resetEditing(); overlay.setInput(nil)
        } else { stopDetection() }
    }

    private func publishDetectionState(found: Bool = false, activity: String) {
        overlay.setDetectionEnabled(detection.enabled)
        appState?.setExplorationState(active: detection.enabled, found: found, activity: activity)
    }

    private func stopDetection() {
        detection.stop(); cancelMenuTargetSelection()
        scanGeneration += 1; activeScanTask?.cancel(); pendingManualScan = nil
        exploration.suspend()
        if !detection.keepsWindow(pinned: overlay.isSticky) {
            directGeneration += 1; resetEditing(); exploration.end(); overlay.hide()
        }
        publishDetectionState(activity: overlay.isSticky ? "Detection off · Pinned" : "Detection off")
    }

    func clearCache() {
        endExploration()
        Task { await resolver.clearCache() }
    }

    func popupInteractionPreferencesDidChange() {
        guard overlay.isVisible else { return }
        refreshLookupHighlight()
    }

    func setHoverScanningEnabled(_ enabled: Bool) {
        resetHoverActivation()
        appState?.activity = enabled ? "Hover on" : "Hover off"
    }

    func resetHoverActivation() {
        detection.stop()
        exploration.end()
        cancelMenuTargetSelection()
        scanGeneration += 1
        activeScanTask?.cancel()
        pendingManualScan = nil
        clearManualInspection()
        hoverScannedPosition = nil
        lastPosition = NSEvent.mouseLocation
        stableSince = Date()
        temporaryHideDeadline = nil
        overlay.hide()
        clearLookupHighlight()
        appState?.setHoverMatchFound(false)
        appState?.activity = "Ready"
    }

    /// Both invocation paths toggle persistent intent; never capture menu numbers.
    func toggleMenuTargetSelection() -> Bool {
        toggleDetection(at: NSEvent.mouseLocation, waitForTarget: true)
        return detection.enabled
    }

    private func toggleDetection(at point: CGPoint, waitForTarget: Bool) {
        if detection.enabled { stopDetection(); return }
        detection.toggle(); detectionOrigin = point
        scanGeneration += 1; directGeneration += 1
        activeScanTask?.cancel(); pendingManualScan = nil
        resetEditing(); clearManualInspection(); clearLookupHighlight()
        if !overlay.isVisible { overlay.showExploration([], status: "Detection on · Point at an ID", near: point) }
        overlay.setShortcutLabel(pinShortcutLabel)
        publishDetectionState(activity: "Detection on · Point at an ID")
        if waitForTarget || !eligibleDetectionTarget(point) { armDetectionTarget() }
        else { resumeDetectionIfAvailable() }
        if appState?.screenRecordingGranted != true { appState?.requestScreenRecording() }
    }

    private func armDetectionTarget() {
        cancelMenuTargetSelection()
        menuTargetGeneration += 1
        let generation = menuTargetGeneration
        menuTargetSelection = MenuBarTargetSelection(now: Date(), expires: false)
        // Mouse-only, passive observation: never swallow a target-app click or
        // request keyboard monitoring. Dwell works even without this monitor.
        menuTargetClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let position = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, self.menuTargetGeneration == generation else { return }
                _ = self.advanceMenuTargetSelection(at: position, clicked: true)
            }
        }
    }

    func cancelMenuTargetSelection() {
        guard menuTargetSelection != nil else { return }
        menuTargetSelection = nil
        menuTargetGeneration += 1
        if let monitor = menuTargetClickMonitor { NSEvent.removeMonitor(monitor) }
        menuTargetClickMonitor = nil
        lastPosition = NSEvent.mouseLocation
        stableSince = Date()
    }

    private func eligibleDetectionTarget(_ position: CGPoint) -> Bool {
        let inContent = NSScreen.screens.contains { screen in
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return ExplorationSession.displayIsAwake(screen) && MenuBarTargetSelection.isContent(position: position, screenFrame: screen.frame, menuHeight: height)
        }
        return inContent && !NSApp.windows.contains { !$0.ignoresMouseEvents && $0.isVisible && $0.frame.contains(position) }
    }

    private func resumeDetectionIfAvailable() {
        guard detection.enabled, !exploration.automaticEnabled, menuTargetSelection == nil else { return }
        guard appState?.screenRecordingGranted == true else {
            publishDetectionState(activity: "Detection paused · Screen Recording required"); return
        }
        if !NSScreen.screens.contains(where: { $0.frame.contains(detectionOrigin) }) {
            detectionOrigin = NSEvent.mouseLocation
            if !eligibleDetectionTarget(detectionOrigin) { armDetectionTarget(); return }
        }
        exploration.start(at: detectionOrigin)
        if !exploration.automaticEnabled { publishDetectionState(activity: "Detection paused · Display unavailable") }
    }

    private func advanceMenuTargetSelection(at position: CGPoint, clicked: Bool = false) -> Bool {
        guard var selection = menuTargetSelection else { return false }
        let decision = selection.update(position: position, eligible: eligibleDetectionTarget(position),
                                        now: Date(), clicked: clicked,
                                        permissionGranted: appState?.screenRecordingGranted == true)
        menuTargetSelection = selection
        switch decision {
        case .waiting: break
        case .cancelled: cancelMenuTargetSelection()
        case let .scan(target):
            cancelMenuTargetSelection() // Consume ownership before OCR or another mouse event.
            detectionOrigin = target
            resumeDetectionIfAvailable()
        }
        return true
    }

    func performInspectCommand(at target: CGPoint? = nil) {
        toggleDetection(at: target ?? NSEvent.mouseLocation, waitForTarget: false)
    }

    func performPinCommand() {
        let state: PanelInteractionState = overlay.isSticky
            ? (overlay.isActive ? .pinnedActive : .pinnedInactive)
            : (overlay.isVisible ? .temporary : .hidden)
        let action = PinCommandPolicy.action(for: state)
        if PinCommandPolicy.clearsManualInspection(for: action) { clearManualInspection() }
        switch action {
        case .closePinned:
            togglePinFromOverlay(); return
        case .focusPinned:
            overlay.focusPinned()
            appState?.activity = overlay.selectedLine.map { "Pinned · \($0.title)" } ?? "Pinned navigator"
            return
        case .pinTemporary:
            resetEditing()
            beginPinnedScanOwnership()
            overlay.pin(shortcutLabel: pinShortcutLabel)
            syncSelectionContext()
            refreshLookupHighlight()
            appState?.activity = "Pinned"
            return
        case .openPinned:
            resetEditing()
            beginPinnedScanOwnership()
        }
        overlay.openPinned(shortcutLabel: pinShortcutLabel)
        guard appState?.screenRecordingGranted == true else {
            overlay.showPinnedStatus("Screen Recording permission is required")
            appState?.requestScreenRecording()
            return
        }
        if !detection.enabled { performInspectCommand() }
    }

    private func tick() {
        overlay.updatePointerPresentation()
        if Date().timeIntervalSince(lastPermissionPollAt) >= 1 {
            let granted = CGPreflightScreenCaptureAccess()
            if appState?.screenRecordingGranted != granted {
                appState?.screenRecordingGranted = granted
                if !granted {
                    exploration.suspend(clearAnchors: true)
                    scanGeneration += 1; activeScanTask?.cancel(); pendingManualScan = nil
                    clearLookupHighlight()
                    publishDetectionState(activity: detection.enabled ? "Detection paused · Screen Recording required" : "Detection off")
                }
            }
            lastPermissionPollAt = Date()
        }
        if advanceMenuTargetSelection(at: NSEvent.mouseLocation) { return }
        resumeDetectionIfAvailable()
        if exploration.isActive { exploration.tick(); return }
        // No unsolicited hover scans after upgrading from any legacy mode.
        guard overlay.isSticky else { return }
        validateLookupSourceIfNeeded()
        if overlay.isSticky {
            // Sticky presentation owns its own local Escape handling and must
            // never inherit the temporary card's movement/lifetime state.
            clearManualInspection()
            return
        }
        let now = Date()
        let position = NSEvent.mouseLocation
        let moved = hypot(position.x - lastPosition.x, position.y - lastPosition.y) > 4
        let manualLifetimeExpired = manualInspection.map { now.timeIntervalSince($0.startedAt) >= ManualInspectionPolicy.lifetime } ?? false
        if overlay.isVisible {
            if overlay.containsPointer {
                temporaryHideDeadline = nil
                lastPosition = position
                stableSince = now
                return
            }
            if TemporaryOverlayLifetimePolicy.shouldHide(
                deadline: temporaryHideDeadline,
                now: now,
                pointerInside: false
            ) {
                temporaryHideDeadline = nil
                dismissManualInspection()
                return
            }
            if temporaryHideDeadline != nil { return }
            if TemporaryOverlayLifetimePolicy.shouldScheduleHide(
                isVisible: true,
                isPinned: false,
                pointerInside: false,
                movedFromLastPosition: moved,
                manualLifetimeExpired: manualLifetimeExpired
            ) {
                temporaryHideDeadline = now.addingTimeInterval(TemporaryOverlayLifetimePolicy.exitGrace)
                lastPosition = position
                stableSince = now
                return
            }
        }
        if let manualInspection {
            let distance = hypot(position.x - manualInspection.anchor.x, position.y - manualInspection.anchor.y)
            if pendingManualScan != nil,
               hypot(position.x - lastPosition.x, position.y - lastPosition.y) > 4 {
                invalidateForPointerMovement(at: position)
                return
            }
            if ManualInspectionPolicy.shouldDismiss(
                distanceFromAnchor: distance,
                elapsed: now.timeIntervalSince(manualInspection.startedAt)
            ) {
                dismissManualInspection()
            }
            return
        }
        let preferences = appState?.activationPreferences ?? .defaults
        if preferences != observedActivationPreferences {
            observedActivationPreferences = preferences
            scanGeneration += 1
            activeScanTask?.cancel()
            pendingManualScan = nil
            hoverScannedPosition = nil
            stableSince = now
            overlay.hide()
            clearLookupHighlight()
            appState?.activity = "Ready"
        }
        if moved {
            invalidateForPointerMovement(at: position)
        }
#if DEBUG
        if CommandLine.arguments.contains("--menu-hover-active-probe") ||
            CommandLine.arguments.contains("--menu-match-probe") { return }
#endif
        guard appState?.screenRecordingGranted == true else { return }
        guard HoverInvocationPolicy.shouldTrigger(
            preferences: preferences,
            hoverEnabled: appState?.hoverScanningEnabled == true,
            stableDuration: now.timeIntervalSince(stableSince),
            locationAlreadyScanned: hoverScannedPosition != nil
        ) else { return }
        switch preferences.mode {
        case .off, .pressToScan:
            return
        case .toggleHover:
            if trigger(at: position, presentation: .temporary, source: .automaticHover, requiresStablePointer: true) {
                hoverScannedPosition = position
            }
        }
    }

    @discardableResult
    private func trigger(
        at position: CGPoint,
        presentation: Presentation,
        source: ScanInvocationSource,
        showInvokedCue: Bool = true,
        requiresStablePointer: Bool
    ) -> Bool {
        guard !isScanning, let plan = CapturePlan.around(position) else { return false }
        guard CGPreflightScreenCaptureAccess() else { appState?.screenRecordingGranted = false; return false }
        let generation = scanGeneration
        let startedDirectGeneration = directGeneration
        let startedEditGeneration = pinnedEditGeneration
        if presentation == .pinned { pinnedInputClaimedCurrentScan = false }
        clearLookupHighlight()
        // Capture once per accepted scan (never on the 20 Hz pointer timer). Keeping this
        // uncached preserves the foreground window title that belongs to this invocation.
        let foreground = ForegroundApplicationContext.capture()
        let lookupSource = LookupSourceSnapshot.capture()
        if presentation == .temporary, !requiresStablePointer {
            manualInspection = ManualInspectionState(anchor: position, startedAt: Date())
            lastPosition = position
        }
        isScanning = true; appState?.activity = "Reading near cursor…"
        if appState?.activationPreferences.scanFeedbackEnabled == true,
           showInvokedCue,
           ScanCuePolicy.showsInvoked(for: source) {
            scanFeedback.invoked(at: position)
        }
        if presentation == .pinned, overlay.isSticky { overlay.showPinnedStatus("Reading near pointer…") }
        activeScanTask = Task {
            defer { finishScan(completedGeneration: generation) }
            let fragments = await ocr.recognizeFragments(plan: plan)
            guard !Task.isCancelled else { return }
            let input = Self.contextInput(from: fragments)
            let tokens = TokenParser.parse(input)
            let context = ResolutionContext.load()
            let history = ResolutionHistoryStore.load()
            let resolutionPlan = await evidencePlanner.plan(
                input: input,
                context: context,
                pinned: PinnedTicketContext.load(fallback: context),
                foreground: foreground,
                history: history
            )
            guard !Task.isCancelled else { return }
            let anchorSourceOrders = Set(ScanAnchorPolicy.sourceOrders(tokens: tokens, plan: resolutionPlan))
            let anchorPairs = tokens.filter { anchorSourceOrders.contains($0.sourceOrder) }.compactMap { token in
                ScanFeedbackAnchor(token: token, fragments: fragments).map { (token.sourceOrder, $0) }
            }
            let anchorsBySourceOrder = anchorPairs.reduce(into: [Int: ScanFeedbackAnchor]()) { result, pair in
                result[pair.0] = pair.1
            }
            let selectedAnchor = resolutionPlan.proposals.first.flatMap { anchorsBySourceOrder[$0.sourceOrder] }
            guard ScanFeedbackLifecyclePolicy.permits(
                .recognized,
                startedGeneration: generation,
                currentGeneration: scanGeneration
            ) else { return }
            if appState?.activationPreferences.scanFeedbackEnabled == true {
                scanFeedback.recognized(anchors: anchorPairs.map(\.1), selected: selectedAnchor)
            }
            let resolved = await resolver.resolve(resolutionPlan)
            guard !Task.isCancelled else { return }
            let terminalEvent: ScanFeedbackLifecycleEvent = resolved.isEmpty ? .noMatch : .resolved
            guard ScanFeedbackLifecyclePolicy.permits(
                terminalEvent,
                startedGeneration: generation,
                currentGeneration: scanGeneration
            ) else { return }
            let lines = Self.presentationLines(from: resolved)
            if let first = resolved.first {
                recordLearningIfEligible(first, in: resolutionPlan, foreground: foreground)
            }
            if appState?.activationPreferences.scanFeedbackEnabled == true {
                guard ScanFeedbackLifecyclePolicy.permits(
                    terminalEvent,
                    startedGeneration: generation,
                    currentGeneration: scanGeneration
                ) else { return }
                switch ScanCuePolicy.terminal(
                    for: source,
                    hasResolvedResult: !resolved.isEmpty
                ) {
                case .noMatch:
                    scanFeedback.noMatch()
                case .none:
                    scanFeedback.cancel()
                }
            }
            if presentation == .pinned {
                guard overlay.isSticky,
                      PinnedScanOwnershipPolicy.permitsCompletion(
                        startedScanGeneration: generation,
                        currentScanGeneration: scanGeneration,
                        startedDirectGeneration: startedDirectGeneration,
                        currentDirectGeneration: directGeneration,
                        startedEditGeneration: startedEditGeneration,
                        currentEditGeneration: pinnedEditGeneration
                      ) else { return }
                if lines.isEmpty {
                    clearLookupHighlight()
                    overlay.showPinnedStatus(tokens.isEmpty ? "No nearby ticket token" : "No real ticket match")
                    appState?.activity = tokens.isEmpty ? "No nearby ticket token" : "No match"
                } else {
                    overlay.replacePinnedResults(lines); syncSelectionContext()
                    installLookupAnchors(
                        resolved: resolved,
                        allAnchors: anchorPairs.map(\.1),
                        anchorsBySourceOrder: anchorsBySourceOrder,
                        fallback: selectedAnchor,
                        source: lookupSource
                    )
                    refreshLookupHighlight(animateFound: true)
                    appState?.activity = lines.first?.title ?? "Pinned"
                }
                return
            }
            guard !overlay.isSticky,
                  (!requiresStablePointer || hypot(NSEvent.mouseLocation.x - position.x, NSEvent.mouseLocation.y - position.y) <= 4) else { return }
            if lines.isEmpty {
                clearLookupHighlight()
                if source == .automaticHover { appState?.setHoverMatchFound(false) }
                overlay.hide(); clearManualInspection(); appState?.activity = tokens.isEmpty ? "No nearby ticket token" : "No match"
            } else {
                if source == .automaticHover { appState?.setHoverMatchFound(true) }
                overlay.show(lines, near: position, shortcutLabel: pinShortcutLabel)
                installLookupAnchors(
                    resolved: resolved,
                    allAnchors: anchorPairs.map(\.1),
                    anchorsBySourceOrder: anchorsBySourceOrder,
                    fallback: selectedAnchor,
                    source: lookupSource
                )
                refreshLookupHighlight(animateFound: true)
                temporaryHideDeadline = nil
                appState?.activity = lines.first?.title ?? "Ready"
            }
        }
        return true
    }

    private func finishScan(completedGeneration: Int) {
        isScanning = false
        activeScanTask = nil
        guard let pending = pendingManualScan else { return }
        pendingManualScan = nil
        guard QueuedScanLifecyclePolicy.shouldLaunch(
            queuedGeneration: pending.generation,
            currentGeneration: scanGeneration,
            completedGeneration: completedGeneration
        ) else {
            appState?.activity = overlay.isSticky ? "Pinned navigator" : "Ready"
            return
        }
        if !trigger(
            at: pending.position,
            presentation: pending.presentation,
            source: pending.source,
            showInvokedCue: !pending.invokedFeedbackShown,
            requiresStablePointer: false
        ) {
            appState?.activity = overlay.isSticky ? "Pinned navigator" : "Ready"
        }
    }

    private func recordLearningIfEligible(
        _ resolved: ResolvedCandidate,
        in plan: ResolutionPlan,
        foreground: ForegroundApplicationContext?
    ) {
        guard let decision = plan.learningDecision(for: resolved.proposal) else { return }
        ResolutionHistoryStore.record(decision, bundleIdentifier: foreground?.bundleIdentifier)
        guard let project = resolved.proposal.inferredProject,
              case let .issue(tracker, _) = resolved.proposal.spec else { return }
        var context = ResolutionContext.load()
        context.saw(project: project, on: tracker)
    }

    private var pinShortcutLabel: String { appState?.pinHotKey?.label ?? "Pin shortcut" }

    private func togglePinFromOverlay() {
        if overlay.isSticky {
            resetEditing()
            overlay.unpin()
            if !detection.keepsWindow(pinned: false) { closePinned(); return }
            refreshLookupHighlight()
            clearManualInspection()
            temporaryHideDeadline = nil
            lastPosition = NSEvent.mouseLocation
            stableSince = Date()
            appState?.activity = overlay.selectedLine?.title ?? "Ready"
            return
        }
        resetEditing()
        beginPinnedScanOwnership()
        temporaryHideDeadline = nil
        overlay.pin(shortcutLabel: pinShortcutLabel)
        syncSelectionContext()
        refreshLookupHighlight()
        appState?.activity = "Pinned"
    }

    private func cycleProject(_ direction: Int) {
        if overlay.selectedLine?.id.hasPrefix("run:") == true {
            overlay.setInput("Workflow runs keep their GitHub repository; paste a scoped reference to switch")
            return
        }
        exploration.holdPresentation()
        directGeneration += 1; resetEditing()
        syncSelectionContext()
        guard let number = currentNumber else {
            overlay.setInput("Type a ticket number first"); return
        }
        let projects = ProjectDescriptor.known
        let currentIndex = projects.firstIndex(where: { $0.key == currentProject }) ?? 0
        let next = projects[(currentIndex + direction + projects.count) % projects.count]
        currentProject = next.key
        resolveDirect(project: next, number: number)
    }

    private var currentProject: String {
        get {
            if let (project, _) = overlay.selectedLine.flatMap({ Self.projectAndNumber(from: $0.key) }) { return project }
            return PinnedTicketContext.load().project
        }
        set {
            var context = PinnedTicketContext.load(); context.project = newValue; context.persist()
        }
    }
    private var currentNumber: Int? {
        if let (_, number) = overlay.selectedLine.flatMap({ Self.projectAndNumber(from: $0.key) }) { return number }
        return PinnedTicketContext.load().number
    }

    private func syncSelectionContext() {
        guard let (project, number) = overlay.selectedLine.flatMap({ Self.projectAndNumber(from: $0.key) }) else { return }
        PinnedTicketContext(project: project, number: number).persist()
    }

    private func handleInput(_ event: PinnedInputEvent) {
        if eventClaimsPinnedResults(event) {
            exploration.holdPresentation()
            pinnedEditGeneration += 1
            directGeneration += 1
            claimPinnedInputOwnershipIfNeeded()
        }
        switch event {
        case let .digits(value):
            editState.appendDigits(value)
            overlay.setInput("\(currentProject)-\(editState.numberBuffer ?? "")")
            scheduleResolve(after: 0.25)
        case let .letters(value):
            editState.appendLetters(value, currentProject: currentProject)
            previewProjectAndSchedule()
        case .backspace:
            switch editState.backspace() {
            case .project:
                previewProjectAndSchedule()
            case .number:
                let value = editState.numberBuffer ?? ""
                overlay.setInput(value.isEmpty ? nil : "\(currentProject)-\(value)")
                if !value.isEmpty { scheduleResolve(after: 0.25) }
            case .none:
                break
            }
        case .submit:
            editTask?.cancel(); commitEditing()
        case .escape:
            escapeInspection()
        case let .paste(value):
            applyPaste(value)
        }
    }

    private func previewProjectAndSchedule() {
        editTask?.cancel()
        guard !editState.projectQuery.isEmpty else { overlay.setInput(nil); return }
        let match = ProjectMatcher.bestMatch(for: editState.projectQuery, current: currentProject)
        overlay.setInput(editState.projectQuery, projectPreview: match?.key)
        scheduleResolve(after: 0.32)
    }

    private func scheduleResolve(after delay: TimeInterval) {
        editTask?.cancel()
        editTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.commitEditing() }
        }
    }

    private func commitEditing() {
        if !editState.projectQuery.isEmpty {
            guard let match = ProjectMatcher.bestMatch(for: editState.projectQuery, current: currentProject) else { return }
            currentProject = match.key
            let number = currentNumber
            editState.clear()
            if let number { resolveDirect(project: match, number: number) }
            else { overlay.setInput(match.key) }
            return
        }
        guard let numberBuffer = editState.numberBuffer, let number = Int(numberBuffer), number > 0 else { return }
        editState.numberBuffer = nil
        PinnedTicketContext(project: currentProject, number: number).persist()
        let project = ProjectDescriptor.known.first(where: { $0.key == currentProject })
            ?? ProjectDescriptor(key: currentProject, name: currentProject, aliases: [], tracker: ResolutionContext.load().lastSeenTracker)
        resolveDirect(project: project, number: number)
    }

    private func applyPaste(_ raw: String) {
        let typed = ScreenReferenceClassifier.classify(OCRContextInput(lines: [raw])).filter {
            $0.isVisibleCandidate && ($0.category == .workflowRun || $0.category == .pullRequest)
        }
        if !typed.isEmpty {
            guard typed.count == 1, let reference = typed.first else {
                overlay.setInput("Paste one complete reference at a time"); return
            }
            guard let spec = reference.spec else { overlay.setInput(reference.reason); return }
            resetEditing(); directGeneration += 1
            let generation = directGeneration
            overlay.setInput("Checking \(reference.category.title) \(reference.token.raw)…")
            editTask = Task { [weak self] in
                guard let self else { return }
                let line = await resolver.resolve(spec)
                guard !Task.isCancelled, generation == directGeneration, overlay.isVisible else { return }
                if let line {
                    overlay.replacePinnedResults([line], selecting: line.key)
                    overlay.setInput(nil); appState?.activity = line.title
                } else {
                    overlay.showPinnedStatus("No verified match for \(reference.token.raw)")
                    appState?.activity = "No match"
                }
            }
            return
        }
        if raw.range(of: #"(?i)\bgh\b|/actions/runs/|/pull/|\b(?:issue_id|user_id|reference_count)\s*[\"']?\s*:"#, options: .regularExpression) != nil {
            overlay.setInput("Paste a complete supported reference with its repository; internal IDs are not ticket keys")
            return
        }
        guard let token = TokenParser.parse([raw.uppercased()]).first else {
            overlay.setInput("Paste did not contain a ticket"); NSSound.beep(); return
        }
        switch token.kind {
        case let .issueKey(project, number):
            PinnedTicketContext(project: project, number: number).persist()
            let descriptor = ProjectDescriptor.known.first(where: { $0.key == project })
                ?? ProjectDescriptor(key: project, name: project, aliases: [], tracker: CandidatePlanner.tracker(for: project, context: .load()))
            resetEditing(); resolveDirect(project: descriptor, number: number)
        case let .hashNumber(number), let .bareNumber(number):
            PinnedTicketContext(project: currentProject, number: number).persist()
            let descriptor = ProjectDescriptor.known.first(where: { $0.key == currentProject })
                ?? ProjectDescriptor(key: currentProject, name: currentProject, aliases: [], tracker: ResolutionContext.load().lastSeenTracker)
            resetEditing(); resolveDirect(project: descriptor, number: number)
        case .version:
            overlay.setInput("Paste did not contain a ticket"); NSSound.beep()
        }
    }

    private func resolveDirect(project: ProjectDescriptor, number: Int) {
        claimPinnedInputOwnershipIfNeeded()
        editTask?.cancel(); directGeneration += 1
        let generation = directGeneration
        let key = "\(project.key)-\(number)"
        PinnedTicketContext(project: project.key, number: number).persist()
        overlay.setInput(key); appState?.activity = "Resolving \(key)…"
        var trackers = [project.tracker]
        if !CandidatePlanner.ppmProjects.contains(project.key), !CandidatePlanner.pmaProjects.contains(project.key) {
            trackers.append(project.tracker.other)
        }
        let plan = DirectEntryResolutionPlanner.plan(project: project.key, key: key, trackers: trackers)
        let foreground = ForegroundApplicationContext.capture()
        editTask = Task {
            let resolved = await resolver.resolve(plan).first
            guard !Task.isCancelled, generation == directGeneration, overlay.isVisible else { return }
            if let resolved,
               case let .issue(tracker, _) = resolved.proposal.spec {
                let line = resolved.line
                overlay.replacePinnedResults([line], selecting: line.key)
                if let decision = plan.learningDecision(for: resolved.proposal, userConfirmed: true) {
                    ResolutionHistoryStore.record(decision, bundleIdentifier: foreground?.bundleIdentifier)
                }
                var context = ResolutionContext.load(); context.saw(project: project.key, on: tracker)
                PinnedTicketContext(project: project.key, number: number).persist()
                appState?.activity = line.title
            } else {
                overlay.showPinnedStatus("No real match for \(key)")
                overlay.setInput(key)
                appState?.activity = "No match for \(key)"
            }
        }
    }

    private func resetEditing() {
        editTask?.cancel(); editTask = nil; editState.clear()
    }

    private func beginPinnedScanOwnership() {
        pinnedInputClaimedCurrentScan = false
    }

    private func claimPinnedInputOwnershipIfNeeded() {
        guard PinnedScanOwnershipPolicy.shouldInvalidateForInput(
            alreadyClaimed: pinnedInputClaimedCurrentScan
        ) else { return }
        pinnedInputClaimedCurrentScan = true
        scanGeneration += 1
        activeScanTask?.cancel()
        pendingManualScan = nil
        clearLookupHighlight()
        appState?.activity = "Pinned · editing"
    }

    private func eventClaimsPinnedResults(_ event: PinnedInputEvent) -> Bool {
        if case .escape = event { return false }
        return true
    }

    private func closePinned() {
        detection.stop(); cancelMenuTargetSelection()
        exploration.end()
        clearManualInspection()
        pendingManualScan = nil
        scanGeneration += 1; activeScanTask?.cancel(); directGeneration += 1; resetEditing(); overlay.closePinned(); overlay.hide(); clearLookupHighlight()
        lastPosition = NSEvent.mouseLocation; stableSince = Date(); hoverScannedPosition = nil; appState?.setHoverMatchFound(false); appState?.activity = "Ready"
    }

    private func clearManualInspection() {
        manualInspection = nil
    }

    private func dismissManualInspection() {
        clearManualInspection()
        scanGeneration += 1
        activeScanTask?.cancel()
        pendingManualScan = nil
        overlay.hide()
        temporaryHideDeadline = nil
        clearLookupHighlight()
        appState?.activity = "Ready"
        lastPosition = NSEvent.mouseLocation
        stableSince = Date()
        hoverScannedPosition = nil
        appState?.setHoverMatchFound(false)
    }

    private func invalidateForPointerMovement(at position: CGPoint) {
        scanGeneration += 1
        activeScanTask?.cancel()
        clearLookupHighlight()
        if let pending = pendingManualScan,
           QueuedScanLifecyclePolicy.shouldRetargetAfterPointerMovement(source: pending.source) {
            let showsFeedback = appState?.activationPreferences.scanFeedbackEnabled == true
            if showsFeedback { scanFeedback.invoked(at: position) }
            pendingManualScan = PendingManualScan(
                position: position,
                presentation: pending.presentation,
                generation: scanGeneration,
                source: pending.source,
                invokedFeedbackShown: showsFeedback
            )
        } else {
            pendingManualScan = nil
        }
        clearManualInspection()
        lastPosition = position
        stableSince = Date()
        hoverScannedPosition = nil
        appState?.setHoverMatchFound(false)
        overlay.hide()
        temporaryHideDeadline = nil
        appState?.activity = "Ready"
    }

    private func installLookupAnchors(
        resolved: [ResolvedCandidate],
        allAnchors: [ScanFeedbackAnchor],
        anchorsBySourceOrder: [Int: ScanFeedbackAnchor],
        fallback: ScanFeedbackAnchor?,
        source: LookupSourceSnapshot?
    ) {
        guard LookupSourceLifecyclePolicy.remainsValid(
            scanned: source,
            current: LookupSourceSnapshot.capture()
        ) else {
            clearLookupHighlight()
            return
        }
        detectedAnchors = allAnchors
        lookupSourceSnapshot = source
        lastLookupSourceValidationAt = Date()
        lookupAnchorByLineID = resolved.reduce(into: [:]) { result, candidate in
            guard result[candidate.line.id] == nil,
                  let anchor = anchorsBySourceOrder[candidate.proposal.sourceOrder] else { return }
            result[candidate.line.id] = anchor
        }
        if let first = resolved.first, lookupAnchorByLineID[first.line.id] == nil, let fallback {
            lookupAnchorByLineID[first.line.id] = fallback
        }
    }

    private func refreshLookupHighlight(
        selecting line: TicketLine? = nil,
        animateFound: Bool = false
    ) {
        let selectedLine = line ?? overlay.selectedLine
        let selectedAnchor = selectedLine.flatMap { lookupAnchorByLineID[$0.id] }
        guard LookupHighlightVisibilityPolicy.shouldShow(
            popupVisible: overlay.isVisible,
            mappedAnchorAvailable: selectedAnchor != nil
        ), let selectedAnchor else {
            scanFeedback.cancel()
            return
        }
        let showAll = overlay.isSticky && (appState?.popupInteractionPreferences.showAllDetectedIDsWhenPinned == true)
        scanFeedback.highlight(
            anchors: detectedAnchors,
            selected: selectedAnchor,
            showAll: showAll,
            animateFound: animateFound
        )
    }

    private func clearLookupHighlight() {
        detectedAnchors = []
        lookupAnchorByLineID = [:]
        lookupSourceSnapshot = nil
        scanFeedback.cancel()
    }

    private func invalidateLookupSource() {
        guard lookupSourceSnapshot != nil else { return }
        clearLookupHighlight()
    }

    private func validateLookupSourceIfNeeded() {
        guard let lookupSourceSnapshot,
              Date().timeIntervalSince(lastLookupSourceValidationAt)
                >= LookupSourceLifecyclePolicy.validationInterval else { return }
        lastLookupSourceValidationAt = Date()
        guard LookupSourceLifecyclePolicy.remainsValid(
            scanned: lookupSourceSnapshot,
            current: LookupSourceSnapshot.capture()
        ) else {
            invalidateLookupSource()
            return
        }
    }

    private static func projectAndNumber(from key: String) -> (String, Int)? {
        guard let token = TokenParser.parse([key]).first,
              case let .issueKey(project, number) = token.kind else { return nil }
        return (project, number)
    }

    private static func contextInput(from fragments: [RecognizedTextFragment]) -> OCRContextInput {
        OCRContextInput(fragments: fragments.enumerated().map { index, fragment in
            OCRContextFragment(
                text: fragment.text,
                lineIndex: index,
                order: index,
                confidence: Double(fragment.confidence),
                region: OCRNormalizedRegion(
                    x: fragment.normalizedBounds.minX,
                    y: fragment.normalizedBounds.minY,
                    width: fragment.normalizedBounds.width,
                    height: fragment.normalizedBounds.height
                )
            )
        })
    }

    private static func presentationLines(from resolved: [ResolvedCandidate]) -> [TicketLine] {
        HoverResultPolicy.visible(from: resolved.map { result in
            let provenance = result.proposal.provenanceSummary
            let metadata = [result.line.metadata, provenance.isEmpty ? nil : "Matched: \(provenance)"]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return TicketLine(
                key: result.line.key,
                state: result.line.state,
                title: result.line.title,
                source: result.line.source,
                metadata: metadata,
                detail: result.line.detail,
                destination: result.line.destination
            )
        })
    }

}
