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
#if DEBUG
        let overlay = OverlayController()
        overlay.configurePermissionGuide(flow)
        overlay.showExploration([], status: "Should be replaced", near: NSEvent.mouseLocation)
        check(overlay.debugPermissionGuideVisible, "inspection window replaces normal UI while blocked")
        let ready = ScreenRecordingPermissionFlow(granted: true, appURL: nil)
        overlay.configurePermissionGuide(ready)
        check(!overlay.debugPermissionGuideVisible, "ready session uses normal inspection UI")
        overlay.hide()
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
