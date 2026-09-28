import AppKit
import SwiftUI

@MainActor final class ScreenRecordingPermissionFlow: ObservableObject {
    @Published private(set) var granted: Bool
    @Published private(set) var access: ScreenRecordingAccess
    @Published private(set) var restartRequired = false
    @Published private(set) var restarting = false
    @Published private(set) var removingApproval = false
    @Published private(set) var verification: ScreenRecordingVerification?
    @Published var error: String?
    let appURL: URL?
    var onGrantedChange: ((Bool) -> Void)?
    private var consecutiveStaleSamples = 0
    private var helper: PermissionHelperController?
    private let restarter = PermissionRestarter()
    var needsGuidance: Bool { !granted || access == .stale || restartRequired }
    var captureAllowed: Bool { !needsGuidance }
    var blockedStatus: String {
        switch access {
        case .stale: return "Screen Recording needs to be allowed again"
        case .missing: return "Screen Recording required"
        case .ready, .unconfirmed: return "Restart to finish setup"
        }
    }
    var menuActionTitle: String {
        access == .stale ? "Allow Screen Recording Again…" : "Grant Screen Recording…"
    }

    init(granted: Bool = CGPreflightScreenCaptureAccess(), appURL: URL? = AppRelaunch.bundleURL()) {
        self.granted = granted
        self.access = granted ? .unconfirmed : .missing
        self.appURL = appURL
    }

    func update(granted: Bool) {
        guard self.granted != granted else { return }
        self.granted = granted
        if granted {
            if access == .missing { access = .unconfirmed }
        } else {
            access = .missing
        }
    }

    func pausedActivity(detectionEnabled: Bool) -> String {
        guard detectionEnabled else { return "Detection off" }
        switch access {
        case .stale: return "Detection paused · Screen Recording needs to be allowed again"
        case .missing: return "Detection paused · Screen Recording required"
        case .ready, .unconfirmed: return "Detection paused · Restart to finish setup"
        }
    }

    func recheckAccess() {
        sampleAccess(confirmStaleImmediately: false)
    }

    func verifyAccess() {
        error = nil
        sampleAccess(confirmStaleImmediately: true)
        noteVerification()
    }

    /// A background poll waits for two stale samples so one untitled window
    /// cannot pause detection or offer to remove a working grant. Verify access
    /// is an explicit check and commits the result immediately.
    func applyLiveVerdict(_ next: ScreenRecordingAccess, preflightGranted: Bool, confirmStaleImmediately: Bool) {
        let committed: ScreenRecordingAccess
        if next == .stale {
            consecutiveStaleSamples += 1
            if confirmStaleImmediately || consecutiveStaleSamples >= 2 || access == .stale {
                committed = .stale
            } else {
                committed = access == .missing ? .unconfirmed : access
            }
        } else {
            consecutiveStaleSamples = 0
            committed = next
        }
        record(preflightGranted: preflightGranted, access: committed)
    }

    func noteVerification() {
        switch access {
        case .ready: verification = .confirmed
        case .unconfirmed: verification = .needAnotherWindow
        case .stale: verification = .stillBlocked
        case .missing: verification = nil
        }
    }

    func record(preflightGranted: Bool, access next: ScreenRecordingAccess) {
        if access != next, next == .stale || next == .missing { verification = nil }
        let changedGrant = granted != preflightGranted
        granted = preflightGranted
        access = next
        if next == .ready { restartRequired = false }
        if changedGrant { onGrantedChange?(granted) }
    }

    private func sampleAccess(confirmStaleImmediately: Bool) {
        let preflight = CGPreflightScreenCaptureAccess()
        applyLiveVerdict(
            ScreenCaptureAccessPolicy.verdict(
                preflightGranted: preflight,
                windows: ScreenCaptureAccessProbe.currentWindows(),
                ownPID: ProcessInfo.processInfo.processIdentifier
            ),
            preflightGranted: preflight,
            confirmStaleImmediately: confirmStaleImmediately
        )
    }

    func removeStaleApproval() {
        guard access == .stale, !removingApproval else { return }
        error = nil
        removingApproval = true
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
        Task { [weak self] in
            let outcome = await Task.detached {
                ScreenRecordingApprovalReset.run(bundleIdentifier: bundleIdentifier)
            }.value
            guard let self else { return }
            self.removingApproval = false
            switch outcome {
            case .removed:
                self.record(preflightGranted: false, access: .missing)
                self.openSystemSettings()
            case .failed:
                self.openSystemSettings()
                self.error = "Couldn’t remove the old approval. In Screen Recording, select Nuncid and click the minus button."
            }
        }
    }

    func openSystemSettings() {
        error = nil
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
              NSWorkspace.shared.open(url) else {
            error = "Open System Settings → Privacy & Security → Screen Recording."; return
        }
        settingsOpened()
        if helper == nil { helper = PermissionHelperController(flow: self) }
        helper?.show()
    }

    func settingsOpened() { restartRequired = true }

    func restart() {
        guard !restarting else { return }
        error = nil; restarting = true
        restarter.restart { [weak self] message in
            self?.restarting = false
            self?.error = message
        }
    }
}

struct PermissionGuideView: View {
    @ObservedObject var flow: ScreenRecordingPermissionFlow
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(flow.access == .stale ? "Let Nuncid read your screen again" : "Let Nuncid read your screen")
                            .font(.system(size: 25, weight: .bold))
                        Text(flow.access == .stale
                             ? "macOS kept an approval that doesn’t apply to this version. Screen content stays on your Mac."
                             : "One-time setup. Screen content stays on your Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Close setup")
                }
                if flow.access == .stale {
                    step(1, title: "Remove the old approval") {
                        Text("In Screen Recording, select Nuncid and click the minus button. The switch can look on while this version still can’t see other windows.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(flow.removingApproval ? "Removing…" : "Remove old approval") { flow.removeStaleApproval() }
                                .disabled(flow.removingApproval)
                            Button("Open System Settings…") { flow.openSystemSettings() }
                        }
                    }
                    step(2, title: "Add this version") {
                        Text("Drag Nuncid back into Screen Recording, then turn its switch on.")
                            .foregroundStyle(.secondary)
                        PermissionAppTile(appURL: flow.appURL)
                    }
                    step(3, title: "Restart Nuncid") {
                        Text("After the new approval is on, restart. Then verify that other windows are visible.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(flow.restarting ? "Restarting…" : "Restart Nuncid") { flow.restart() }
                                .buttonStyle(.bordered).controlSize(.large).disabled(flow.restarting)
                            Button("Verify access") { flow.verifyAccess() }
                                .buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                } else {
                    step(1, title: "Open Screen Recording") {
                        Button("Open System Settings…") { flow.openSystemSettings() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    step(2, title: "Drag Nuncid into the list") {
                        Text("Drop the app into Screen Recording, then turn its switch on.")
                            .foregroundStyle(.secondary)
                        PermissionAppTile(appURL: flow.appURL)
                    }
                    step(3, title: "Restart Nuncid") {
                        Text(flow.granted ? "Access detected. Restart to finish setup." : "After enabling access, restart to apply it.")
                            .foregroundStyle(.secondary)
                        Button(flow.restarting ? "Restarting…" : "Restart Nuncid") { flow.restart() }
                            .buttonStyle(.bordered).controlSize(.large).disabled(flow.restarting)
                    }
                }
                if let verification = flow.verification {
                    Text(verification.message).font(.callout)
                        .foregroundStyle(verification == .confirmed ? Color.green : Color.secondary)
                }
                if let error = flow.error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func step<Content: View>(_ number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(String(number)).font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor).frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 18, weight: .semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PermissionAppTile: View {
    let appURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 12) {
            if let appURL {
                AppBundleDragSource(url: appURL).frame(height: 68)
                    .accessibilityLabel("Drag Nuncid into the Screen Recording list")
            } else {
                Text("Open the installed Nuncid.app to drag it here.").font(.callout)
            }
            Image(systemName: "arrow.up")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.accentColor)
                .offset(y: pulse && !reduceMotion ? -4 : 0)
                .opacity(pulse && !reduceMotion ? 1 : 0.6)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } } }
        .help("Drag the app icon into Screen Recording. You can also use + and select this app.")
    }
}

private struct AppBundleDragSource: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AppBundleDragView { AppBundleDragView(url: url) }
    func updateNSView(_ view: AppBundleDragView, context: Context) { view.url = url }
}

final class AppBundleDragView: NSView, NSDraggingSource {
    var url: URL
    init(url: URL) {
        self.url = url; super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Nuncid app — drag to Screen Recording, or press to reveal in Finder")
    }
    override func accessibilityPerformPress() -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([url]); return true
    }
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { }
    override func draw(_ dirtyRect: NSRect) {
        let icon = NuncidBrand.appIcon
        icon.draw(in: NSRect(x: 0, y: (bounds.height - 52) / 2, width: 52, height: 52))
        ("Nuncid.app" as NSString).draw(at: NSPoint(x: 65, y: bounds.midY + 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.labelColor])
        ("Drag to allow screen access" as NSString).draw(at: NSPoint(x: 65, y: bounds.midY - 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let location = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: location.x - 26, y: location.y - 26, width: 52, height: 52),
                              contents: NuncidBrand.appIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Prefer free space below Settings, then beside it; on smaller displays keep
/// the compact helper at the bottom without moving another app's window.
enum PermissionHelperPlacement {
    static func frame(settings: CGRect?, visible: CGRect, size: CGSize) -> CGRect {
        let size = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 12)
        if let settings {
            if settings.minY - visible.minY >= size.height + 16 {
                origin = CGPoint(x: settings.midX - size.width / 2, y: settings.minY - size.height - 12)
            } else if visible.maxX - settings.maxX >= size.width + 16 {
                origin = CGPoint(x: settings.maxX + 12, y: settings.minY)
            } else if settings.minX - visible.minX >= size.width + 16 {
                origin = CGPoint(x: settings.minX - size.width - 12, y: settings.minY)
            }
        }
        return CGRect(origin: CGPoint(x: min(max(origin.x, visible.minX), visible.maxX - size.width),
                                      y: min(max(origin.y, visible.minY), visible.maxY - size.height)), size: size)
    }
}

@MainActor final class PermissionHelperController: NSWindowController {
    private let flow: ScreenRecordingPermissionFlow
    private var placementTimer: Timer?
    init(flow: ScreenRecordingPermissionFlow) {
        self.flow = flow
        let height: CGFloat = flow.access == .stale ? 230 : 192
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: height),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Allow Nuncid"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PermissionHelperView(flow: flow))
        super.init(window: panel)
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        if flow.access == .stale, var frame = window?.frame, frame.height < 220 {
            frame.origin.y -= 230 - frame.height
            frame.size.height = 230
            window?.setFrame(frame, display: false)
        }
        place()
        window?.orderFrontRegardless()
        placementTimer?.invalidate()
        // Settings opens asynchronously. Follow its initial layout, then leave
        // the helper where the user puts it instead of chasing every movement.
        var attempts = 0
        placementTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
                self.place(); attempts += 1
                if attempts >= 5 { timer.invalidate() }
            }
        }
    }
    private func place() {
        guard let window else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let bounds = entries.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowBounds as String] as? [String: Any]
        let quartz = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let settings = quartz.map { CGRect(x: $0.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - $0.maxY, width: $0.width, height: $0.height) }
        guard let screen = NSScreen.screens.first(where: { screen in settings.map { $0.intersects(screen.frame) } == true }) else {
            if let visible = NSScreen.main?.visibleFrame { window.setFrame(PermissionHelperPlacement.frame(settings: nil, visible: visible, size: window.frame.size), display: true) }
            return
        }
        window.setFrame(PermissionHelperPlacement.frame(settings: settings, visible: screen.visibleFrame, size: window.frame.size), display: true)
    }
}

private struct PermissionHelperView: View {
    @ObservedObject var flow: ScreenRecordingPermissionFlow
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text(flow.access == .stale ? "Remove Nuncid, then drag it back in" : "Drag Nuncid into Screen Recording").font(.headline)
            PermissionAppTile(appURL: flow.appURL)
            HStack {
                Text(flow.access == .stale ? "Remove the old row, turn the switch on, then restart." : "Turn its switch on, then restart.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if flow.access == .stale {
                    Button(flow.removingApproval ? "Removing…" : "Remove old approval") { flow.removeStaleApproval() }
                        .disabled(flow.removingApproval)
                }
                Button(flow.restarting ? "Restarting…" : "Restart Nuncid") { flow.restart() }.disabled(flow.restarting)
            }
            if let error = flow.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PermissionPrivacyStatus: View {
    @ObservedObject var flow: ScreenRecordingPermissionFlow
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: flow.needsGuidance ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: 34)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(flow.needsGuidance ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 8) {
                Text(ScreenRecordingAccessCopy.settingsTitle(access: flow.access, restartRequired: flow.restartRequired))
                    .font(.headline)
                Text(ScreenRecordingAccessCopy.settingsDetail(access: flow.access, restartRequired: flow.restartRequired))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if flow.needsGuidance {
                        Button("Open System Settings…") { flow.openSystemSettings() }
                        if flow.access == .stale {
                            Button(flow.removingApproval ? "Removing…" : "Remove old approval") { flow.removeStaleApproval() }
                                .disabled(flow.removingApproval)
                        }
                        if flow.restartRequired {
                            Button(flow.restarting ? "Restarting…" : "Restart Nuncid") { flow.restart() }.disabled(flow.restarting)
                        }
                    }
                    if flow.access != .missing {
                        Button("Verify access") { flow.verifyAccess() }
                            .help("Check whether Nuncid can see other windows, not only the Screen Recording switch.")
                    }
                }
                if let verification = flow.verification {
                    Text(verification.message).font(.callout)
                        .foregroundStyle(verification == .confirmed ? Color.green : Color.secondary)
                }
                if let error = flow.error { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
    }
}
