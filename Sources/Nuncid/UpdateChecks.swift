import Foundation
import Sparkle

@MainActor enum UpdateChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let installed = ReleaseIdentity(rawVersion: "260919094934.0.0", scheme: .calendarV2, sequence: 32)!
        let version = "260919120000.0.0"
        let url = URL(string: "https://github.com/markus-barta/nuncid/releases/download/v\(version)/Nuncid-\(version).zip")!
        let description = """
        <!-- nuncid-release-metadata
        version-scheme: inspr-calendar-v2
        version: \(version)
        release-channel: stable
        release-sequence: 33
        -->
        """
        func accepts(_ body: String?, _ candidate: String = version, _ download: URL? = url) -> Bool {
            SignedUpdatePolicy.identity(description: body, displayVersion: candidate, url: download, installed: installed) != nil
        }
        expect(accepts(description), "signed feed release identity accepts a later calendar release")
        expect(!accepts(nil), "missing release scheme fails closed")
        expect(!accepts(description.replacingOccurrences(of: "inspr-calendar-v2", with: "unknown")), "unknown scheme fails closed")
        expect(!accepts(description.replacingOccurrences(of: "33", with: "31")), "release sequence downgrade rejected")
        expect(!accepts(description, "5.0.0"), "display identity mismatch rejected")
        expect(!accepts(description, version, URL(string: "https://example.org/update.zip")), "foreign archive rejected")
        expect(!accepts(description, version, URL(string: url.absoluteString + "?replacement=true")), "noncanonical archive rejected")
        expect(!accepts(description.replacingOccurrences(of: version, with: installed.rawVersion), installed.rawVersion), "same version rejected")
        expect(!accepts(description + "\n" + description), "ambiguous metadata rejected")

        let suite = "Nuncid.UpdateChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserved", forKey: "unrelated.preference")
        let driver = AppUpdater(startingUpdater: false, defaults: defaults)
        expect(driver.automaticallyDownloads, "automatic downloads default on")
        driver.automaticallyDownloads = false
        expect(!AppUpdater(startingUpdater: false, defaults: defaults).automaticallyDownloads, "setting survives restart")
        expect(defaults.string(forKey: "unrelated.preference") == "preserved", "update preference preserves other settings")
        driver.showDownloadInitiated(cancellation: {})
        expect(driver.state == .downloading && !driver.canAct, "download is not ready")
        driver.showDownloadDidStartExtractingUpdate()
        expect(driver.state == .verifying && !driver.canAct, "unverified archive is not ready")
        var installs = 0
        driver.showReady(toInstallAndRelaunch: { if $0 == .install { installs += 1 } })
        expect(driver.state == .ready && driver.canAct && installs == 0, "verified update waits for the user")
        expect(driver.state.title == "Restart to Update", "short menu title")
        driver.performAction()
        expect(installs == 1 && driver.state == .installing, "menu action installs once")
        driver.performAction()
        expect(installs == 1, "double click cannot restart twice")
        var acknowledged = false
        driver.showUpdaterError(NSError(domain: "test", code: 1), acknowledgement: { acknowledged = true })
        expect(acknowledged && driver.state == .failed && !driver.canAct, "failure discards stale install callback")
        driver.showReady(toInstallAndRelaunch: { _ in installs += 1 })
        driver.dismissUpdateInstallation()
        expect(!driver.canAct, "dismissed session cannot invoke stale callback")
        expect(!DownloadUpdateState.failed.busy, "failure permits retry on active updater")
        return failures
    }
}
