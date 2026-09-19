#if DEBUG
import AppKit
import Combine

/// Invoked only by the isolated macOS CI fixture. It never runs in a release
/// build, against the installed app, or with a production update-signing key.
@MainActor enum UpdateIntegrationProbe {
    private static var updater: AppUpdater?
    private static var observation: AnyCancellable?
    static func startIfRequested() -> Bool {
        guard Bundle.main.bundleIdentifier?.hasPrefix("at.markusbarta.nuncid.update-fixture.") == true,
              let output = Bundle.main.object(forInfoDictionaryKey: "NuncidProbeResultPath") as? String else { return false }
        NSApp.setActivationPolicy(.accessory)
        let result = URL(fileURLWithPath: output)
        func record(_ value: String) {
            try? value.write(to: result, atomically: true, encoding: .utf8)
        }
        let defaults = UserDefaults.standard
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            record(defaults.string(forKey: "updateProbe.preserved") == "yes" ? "installed;preferences-preserved" : "preferences-lost")
            Darwin.exit(0)
        }
        defaults.set("yes", forKey: "updateProbe.preserved")
        defaults.synchronize()
        let driver = AppUpdater(startingUpdater: false)
        updater = driver
        let expectsFailure = Bundle.main.object(forInfoDictionaryKey: "NuncidProbeExpectsFailure") as? Bool == true
        observation = driver.$state.sink { state in
            if state == .ready {
                record("ready;waiting-for-user")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard !expectsFailure, !NSApp.windows.contains(where: \.isVisible),
                          Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "1" else {
                        record("unexpected-install-or-window"); Darwin.exit(1)
                    }
                    driver.performAction()
                }
            } else if state == .failed {
                record(expectsFailure ? "rejected;installed-app-preserved" : "unexpected-failure")
                Darwin.exit(expectsFailure ? 0 : 1)
            }
        }
        do { try driver.startIntegrationProbe() }
        catch { record("start-failed"); Darwin.exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 100) { record("timeout"); Darwin.exit(1) }
        return true
    }
}
#endif
