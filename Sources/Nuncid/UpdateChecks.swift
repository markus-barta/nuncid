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
        expect(driver.cadence == .daily && driver.cadence.interval == 86_400, "update checks default to once a day")
        expect(UpdateCheckCadence.weekly.interval == 604_800 && UpdateCheckCadence.developing.interval == 300, "weekly and development intervals")
        let developing = driver.cadence.toggled(standard: .daily)
        expect(developing.cadence == .developing && developing.standard == .daily, "option-click enters 5-minute checks")
        let restored = developing.cadence.toggled(standard: developing.standard)
        expect(restored.cadence == .daily && restored.standard == .daily, "option-click again restores the daily schedule")
        let weekly = UpdateCheckCadence.weekly.toggled(standard: .daily)
        expect(weekly.cadence.toggled(standard: weekly.standard).cadence == .weekly, "option-click restores the previous weekly schedule")
        driver.cadence = .weekly
        expect(AppUpdater(startingUpdater: false, defaults: defaults).cadence == .weekly, "chosen cadence survives restart")
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
        let offlineDriver = AppUpdater(startingUpdater: false, defaults: defaults)
        offlineDriver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001), acknowledgement: {})
        offlineDriver.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        expect(offlineDriver.state == .current, "offline scheduled check preserves prior status")
        offlineDriver.showUserInitiatedUpdateCheck(cancellation: {})
        offlineDriver.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        expect(offlineDriver.state == .checkFailed, "manual offline check reports check failure")
        offlineDriver.showReady(toInstallAndRelaunch: { _ in installs += 1 })
        offlineDriver.fail(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue)))
        expect(offlineDriver.state == .ready && offlineDriver.canAct, "feed failure preserves verified staged update")
        offlineDriver.fail(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue)))
        expect(offlineDriver.state == .failed && !offlineDriver.canAct && offlineDriver.lastFailureWasValidation,
               "signature rejection invalidates readiness and identifies validation failure")
        offlineDriver.fail(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.validationError.rawValue)))
        expect(offlineDriver.lastFailureWasValidation, "Sparkle 2.10 validation error is recognized")
        return failures
    }
}
