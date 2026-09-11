import AppKit
import SwiftUI

@MainActor final class ScreenRecordingPermissionFlow: ObservableObject {
    @Published private(set) var granted: Bool
    @Published private(set) var restartRequired = false
    @Published private(set) var restarting = false
    @Published var error: String?
    let appURL: URL?
    private var helper: PermissionHelperController?
    private let restarter = PermissionRestarter()
    var needsGuidance: Bool { !granted || restartRequired }

    init(granted: Bool = CGPreflightScreenCaptureAccess(), appURL: URL? = AppRelaunch.bundleURL()) {
        self.granted = granted
        self.appURL = appURL
    }

    func update(granted: Bool) {
        guard self.granted != granted else { return }
        self.granted = granted
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
                        Text("Let Nuncid read your screen").font(.system(size: 25, weight: .bold))
                        Text("One-time setup. Screen content stays on your Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Close setup")
                }
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
    private var placementTimer: Timer?
    init(flow: ScreenRecordingPermissionFlow) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 192),
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
            Text("Drag Nuncid into Screen Recording").font(.headline)
            PermissionAppTile(appURL: flow.appURL)
            HStack {
                Text("Turn its switch on, then restart.").font(.callout).foregroundStyle(.secondary)
                Spacer()
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
                Text(flow.needsGuidance ? (flow.granted ? "Restart to finish setup" : "Allow Screen Recording") : "Screen Recording is allowed")
                    .font(.headline)
                Text(flow.needsGuidance ? "Open settings, drag Nuncid into the list, enable it, then restart." : "Nuncid is ready to recognize references on your screen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if flow.needsGuidance {
                    HStack {
                        Button("Open System Settings…") { flow.openSystemSettings() }
                        if flow.restartRequired {
                            Button(flow.restarting ? "Restarting…" : "Restart Nuncid") { flow.restart() }.disabled(flow.restarting)
                        }
                    }
                }
                if let error = flow.error { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
    }
}
