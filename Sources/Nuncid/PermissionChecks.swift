import AppKit
import Darwin

@MainActor enum PermissionChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        let flow = ScreenRecordingPermissionFlow(granted: false, appURL: nil)
        check(flow.needsGuidance, "denied permission gates detection")
        flow.settingsOpened()
        flow.update(granted: true)
        check(flow.granted && flow.needsGuidance && flow.restartRequired, "grant waits for restart")
        flow.settingsOpened()
        check(flow.restartRequired, "repeated setup preserves restart requirement")
        flow.update(granted: false)
        check(flow.needsGuidance, "revocation keeps guidance")
        let restarted = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        check(!restarted.needsGuidance, "fresh process uses granted permission")
        restarted.update(granted: false)
        check(restarted.needsGuidance, "revocation replaces detection UI")
        let own = Int32(42)
        func window(_ pid: Int32, _ layer: Int, _ name: ScreenCaptureWindowName) -> ScreenCaptureWindowRecord {
            ScreenCaptureWindowRecord(ownerPID: pid, layer: layer, name: name)
        }
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: false, windows: [window(7, 0, .titled)], ownPID: own) == .missing,
              "preflight denial ignores visible window titles")
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: true, windows: [window(7, 0, .titled)], ownPID: own) == .ready,
              "another app's window title confirms access")
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: true, windows: [window(7, 0, .absent), window(8, 0, .titled)], ownPID: own) == .ready,
              "one visible foreign title outweighs a stripped window")
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: true, windows: [window(7, 0, .absent), window(own, 0, .titled)], ownPID: own) == .stale,
              "stripped foreign titles are a stale grant")
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: true, windows: [window(7, 0, .empty)], ownPID: own) == .ready,
              "an untitled window that still publishes its name means access works")
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: true, windows: [window(7, 3, .absent), window(own, 0, .titled)], ownPID: own) == .unconfirmed,
              "menu-bar windows and our own titles do not prove or deny access")
        check(ScreenCaptureAccessPolicy.verdict(preflightGranted: true, windows: [], ownPID: own) == .unconfirmed,
              "no other windows leaves the grant unconfirmed")
        let stale = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        stale.settingsOpened()
        stale.record(preflightGranted: true, access: .stale)
        check(stale.granted && stale.needsGuidance && !stale.captureAllowed && stale.restartRequired, "stale grant blocks detection")
        check(stale.blockedStatus == "Screen Recording needs to be allowed again", "stale grant names the menu and toast status")
        check(stale.menuActionTitle == "Allow Screen Recording Again…", "stale grant asks to allow screen recording again")
        check(ScreenRecordingAccessCopy.settingsTitle(access: .stale, restartRequired: false) == "Screen Recording needs to be allowed again",
              "settings names a stale grant")
        check(stale.pausedActivity(detectionEnabled: true) == "Detection paused · Screen Recording needs to be allowed again",
              "detection pauses with the stale-grant reason")
        stale.record(preflightGranted: true, access: .ready)
        check(stale.captureAllowed && !stale.needsGuidance && !stale.restartRequired, "confirmed access clears the restart wait")
        check(ScreenRecordingAccessCopy.settingsTitle(access: .ready, restartRequired: false) == "Screen Recording is allowed",
              "confirmed access keeps the allowed title")
        check(ScreenRecordingAccessCopy.settingsDetail(access: .ready, restartRequired: false) == "Nuncid is ready to recognize references on your screen.",
              "confirmed access keeps the ready detail")
        let unconfirmed = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        unconfirmed.record(preflightGranted: true, access: .unconfirmed)
        unconfirmed.noteVerification()
        check(unconfirmed.verification == .needAnotherWindow, "verify asks for another window when nothing can be compared")
        unconfirmed.record(preflightGranted: true, access: .ready)
        unconfirmed.noteVerification()
        check(unconfirmed.verification == .confirmed, "verify confirms a live grant")
        unconfirmed.record(preflightGranted: true, access: .stale)
        check(unconfirmed.verification == nil, "a stale result clears a previous confirmation")
        unconfirmed.noteVerification()
        check(unconfirmed.verification == .stillBlocked, "verify explains a confirmed stale grant")
        let held = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        held.record(preflightGranted: true, access: .ready)
        held.applyLiveVerdict(.stale, preflightGranted: true, confirmStaleImmediately: false)
        check(held.access == .ready && held.captureAllowed, "one stale sample keeps a working grant")
        held.applyLiveVerdict(.stale, preflightGranted: true, confirmStaleImmediately: false)
        check(held.access == .stale && !held.captureAllowed, "a second stale sample blocks detection")
        let explicit = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        explicit.record(preflightGranted: true, access: .ready)
        explicit.applyLiveVerdict(.stale, preflightGranted: true, confirmStaleImmediately: true)
        check(explicit.access == .stale, "verify access commits one stale sample")
        check(ScreenRecordingApprovalReset.arguments(bundleIdentifier: AppIdentity.bundleIdentifier) == ["reset", "ScreenCapture", AppIdentity.bundleIdentifier],
              "approval reset targets only this app's screen recording entry")
#if DEBUG
        let overlay = OverlayController()
        overlay.configurePermissionGuide(flow)
        overlay.showExploration([], status: "Should be replaced", near: NSEvent.mouseLocation)
        check(overlay.debugPermissionGuideVisible, "inspection window replaces normal UI while blocked")
        let ready = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        overlay.configurePermissionGuide(ready)
        check(!overlay.debugPermissionGuideVisible, "ready session uses normal inspection UI")
        overlay.hide()
        let labeled = OverlayController()
        labeled.setShortcutLabel("F19")
        labeled.showExploration([], status: "Detection on", near: .zero)
        check(labeled.debugShortcutLabel == "F19", "exploration footer keeps the saved pin shortcut")
        labeled.hide()
#endif
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let settings = CGRect(x: 350, y: 300, width: 720, height: 600)
        let size = CGSize(width: 450, height: 220)
        let below = PermissionHelperPlacement.frame(settings: settings, visible: main, size: size)
        check(below.maxY < settings.minY && main.contains(below), "helper fits below Settings")
        for visible in [main, CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                        CGRect(x: 1440, y: 0, width: 800, height: 600), CGRect(x: 0, y: 0, width: 320, height: 180)] {
            for target: CGRect? in [nil, visible.insetBy(dx: 50, dy: 20), CGRect(x: 9999, y: 9999, width: 800, height: 900)] {
                check(visible.contains(PermissionHelperPlacement.frame(settings: target, visible: visible, size: size)), "helper stays on target display")
            }
        }
        let url = URL(fileURLWithPath: "/Applications/A folder/Nuncid's app.app")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([url as NSURL])
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        check(urls == [url], "drag payload is the exact file URL, including spaces")
        if let executable = Bundle.main.executableURL, AppRelaunch.bundleURL() != nil {
            let child = Process(); let pipe = Pipe()
            child.executableURL = executable
            child.arguments = [AppRelaunch.helperFlag, String(getpid())]
            child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            do {
                try child.run()
                let ready = pipe.fileHandleForReading.availableData
                check(String(data: ready, encoding: .utf8) == "ready\n", "packaged relaunch helper handshake")
                check(child.isRunning, "helper waits while original app lives")
                if child.isRunning { child.terminate(); child.waitUntilExit() }
            } catch { failures.append("relaunch helper starts from packaged executable") }
        }
        return failures
    }
}
