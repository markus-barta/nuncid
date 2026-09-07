import Foundation

/// Deterministic policy coverage; runtime UI probes additionally exercise the
/// coordinator, native frame constraints, focus and scroll-event routing.
enum InspectionChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) { if !value { failures.append(name) } }
        var mode = DetectionMode()
        check(!mode.enabled && !mode.keepsWindow(pinned: false) && mode.keepsWindow(pinned: true), "launch off / restored pin")
        for _ in 0..<100 {
            mode.toggle()
            check(mode.enabled && mode.keepsWindow(pinned: false) && mode.keepsWindow(pinned: true), "on visibility independent of pin")
            mode.toggle()
            check(!mode.enabled && !mode.keepsWindow(pinned: false) && mode.keepsWindow(pinned: true), "off pin exception")
        }
        mode.toggle(); mode.stop(); mode.stop()
        check(!mode.enabled, "close/escape stop is idempotent")

        let start = Date(timeIntervalSince1970: 100)
        let point = CGPoint(x: 100, y: 100)
        var waiting = MenuBarTargetSelection(now: start, expires: false)
        check(waiting.update(position: point, eligible: false, now: start.addingTimeInterval(3_600)) == .waiting, "no menu timeout")
        check(waiting.update(position: point, eligible: true, now: start.addingTimeInterval(3_601), clicked: true, permissionGranted: false) == .waiting, "permission pause retains target ownership")
        check(waiting.update(position: point, eligible: true, now: start.addingTimeInterval(3_602)) == .waiting, "resume requires fresh dwell")
        check(waiting.update(position: point, eligible: true, now: start.addingTimeInterval(3_603)) == .scan(point), "resume selects exactly once")
        check(waiting.update(position: point, eligible: true, now: start.addingTimeInterval(3_604), clicked: true) == .cancelled, "consumed target cannot duplicate scan")

        let name = "at.markusbarta.nuncid.inspection-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "presentation.textSize")
        defaults.set("keep", forKey: "inspectHotKey")
        check(InspectionZoom.load(defaults: defaults).percent == 100, "zoom defaults to baseline")
        for percentage in stride(from: 30, through: 300, by: 10) {
            let zoom = InspectionZoom(percentage)
            zoom.persist(defaults: defaults)
            check(InspectionZoom.load(defaults: defaults) == zoom, "zoom roundtrip \(percentage)")
            check(zoom.changed(by: 1).percent == min(300, percentage + 10), "zoom increment")
            check(zoom.changed(by: -1).percent == max(30, percentage - 10), "zoom decrement")
            let baseline = CGSize(width: 1_000, height: 800)
            let requested = zoom.requestedSize(baseline: baseline)
            let roundtrip = zoom.baseline(afterResize: requested)
            check(abs(roundtrip.width - baseline.width) < 0.001 && abs(roundtrip.height - baseline.height) < 0.001, "resize inverses zoom without feedback")
            for visible in [CGRect(x: 2560, y: 0, width: 1512, height: 944), CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 240, height: 120)] {
                let bounded = InspectionZoom.bounded(requested, visible: visible)
                check(bounded.width <= visible.width && bounded.height <= visible.height, "frame never exceeds usable screen")
                check(bounded.width > 0 && bounded.height > 0, "positive frame even on tiny display")
                let origin = PanelPlacement.clamped(origin: CGPoint(x: 9_999, y: -9_999), size: bounded, visibleFrame: visible)
                check(visible.contains(CGRect(origin: origin, size: bounded)), "placement supports negative display origins")
            }
        }
        check(InspectionZoom(-1).percent == 30 && InspectionZoom(301).percent == 300, "saved zoom clamped")
        check(InspectionZoom().percent == 100, "center reset")
        check(defaults.string(forKey: "presentation.textSize") == "keep" && defaults.string(forKey: "inspectHotKey") == "keep", "zoom never changes appearance or shortcuts")
        return failures
    }
}
