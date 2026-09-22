import AppKit
import Combine
import Sparkle

enum UpdateCheckCadence: String, Equatable, CaseIterable, Identifiable {
    case daily
    case weekly
    case developing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .developing: return "Every 5 minutes"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .developing: return 5 * 60
        }
    }

    /// Option-click enters the 5-minute development cadence and restores the
    /// previous day or week choice when clicked again.
    func toggled(standard: Self) -> (cadence: Self, standard: Self) {
        if self == .developing {
            let restored = standard == .developing ? Self.daily : standard
            return (restored, restored)
        }
        return (.developing, self)
    }

    static let storageKey = "updates.checkCadence"
    static let standardStorageKey = "updates.checkCadence.standard"

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: storageKey), let value = Self(rawValue: raw) else { return .daily }
        return value
    }

    static func loadStandard(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: standardStorageKey), let value = Self(rawValue: raw), value != .developing else { return .daily }
        return value
    }
}

enum DownloadUpdateState: Equatable {
    case idle, checking, downloading, verifying, ready, installing, current, checkFailed, failed, unavailable

    var title: String {
        switch self {
        case .idle: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .downloading: return "Downloading Update…"
        case .verifying: return "Verifying Update…"
        case .ready: return "Restart to Update"
        case .installing: return "Restarting…"
        case .current: return "Nuncid is up to date"
        case .checkFailed: return "Retry Update Check"
        case .failed: return "Retry Update"
        case .unavailable: return "Updates unavailable"
        }
    }
    var busy: Bool { [.checking, .downloading, .verifying, .installing].contains(self) }
}

enum SignedUpdatePolicy {
    static let feedURL = "https://github.com/markus-barta/nuncid/releases/latest/download/appcast.xml"

    static func identity(description: String?, displayVersion: String, url: URL?, installed: ReleaseIdentity?) -> ReleaseIdentity? {
        guard let installed, let metadata = ReleaseMetadata.parse(description),
              metadata.version == displayVersion,
              let candidate = ReleaseIdentity(rawVersion: metadata.version, scheme: metadata.scheme, sequence: metadata.sequence),
              candidate.isNewerThan(installed) == true,
              let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let expectedPath = "/markus-barta/nuncid/releases/download/v\(metadata.version)/Nuncid-\(metadata.version).zip"
        guard parts.scheme == "https", parts.host == "github.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == expectedPath else { return nil }
        return candidate
    }

    static func unavailableReason(bundle: Bundle, fileManager: FileManager = .default) -> String? {
        let path = bundle.bundleURL.resolvingSymlinksInPath().path
        guard bundle.bundleURL.pathExtension == "app" else { return "Install the packaged app to enable updates." }
        guard !path.contains("/AppTranslocation/"), !path.contains("/Volumes/") else {
            return "Move Nuncid to Applications, then reopen it to enable updates."
        }
        guard !path.contains("/Caskroom/"), !path.contains("/Cellar/"), !path.contains("/nix/store/") else {
            return "Update this installation with its package manager."
        }
        guard fileManager.isWritableFile(atPath: path),
              fileManager.isWritableFile(atPath: bundle.bundleURL.deletingLastPathComponent().path) else {
            return "This installation is read-only. Install a writable copy to enable updates."
        }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String == feedURL,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true else {
            return "This build does not have a signed update feed configured."
        }
        return nil
    }
}

/// Sparkle owns download validation, persistent staging and replacement. This
/// driver provides menu/settings UI only; background work never creates windows.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    @Published private(set) var state: DownloadUpdateState = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var detail = "Updates download quietly. Restart when it suits you."
    @Published var automaticallyDownloads: Bool {
        didSet {
            defaults.set(automaticallyDownloads, forKey: Self.preferenceKey)
            updater?.automaticallyDownloadsUpdates = automaticallyDownloads
        }
    }
    @Published var cadence: UpdateCheckCadence {
        didSet { persistCadence(checkNow: cadence == .developing && oldValue != .developing) }
    }
    private(set) var standardCadence: UpdateCheckCadence
    static let preferenceKey = "updates.automaticallyDownload"
    private let defaults: UserDefaults
    private var updater: SPUUpdater?
    private var developTimer: Timer?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    private var restartRequested = false
    private var userRequestedCheck = false
    private(set) var lastFailureWasValidation = false
    private(set) var lastFailureCodes: [String] = []
#if DEBUG
    private var integrationProbe = false
    private var settingsPreview = false

    func startIntegrationProbe() throws {
        guard ProcessInfo.processInfo.environment["CI"] == "true",
              Bundle.main.bundleIdentifier?.hasPrefix("at.markusbarta.nuncid.update-fixture.") == true,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "http", url.host == "127.0.0.1" else {
            throw NSError(domain: "Nuncid.UpdateProbe", code: 1)
        }
        integrationProbe = true
        let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = instance
        instance.automaticallyChecksForUpdates = true
        instance.automaticallyDownloadsUpdates = true
        instance.sendsSystemProfile = false
        try instance.start()
        instance.checkForUpdatesInBackground()
    }
#endif
    var available: Bool {
#if DEBUG
        if settingsPreview { return true }
#endif
        return updater != nil
    }
    var canAct: Bool { (available || installReply != nil) && !state.busy }

    init(startingUpdater: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyDownloads = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        cadence = UpdateCheckCadence.load(defaults: defaults)
        standardCadence = UpdateCheckCadence.loadStandard(defaults: defaults)
        super.init()
#if DEBUG
        if CommandLine.arguments.contains("--settings-updates-probe") {
            settingsPreview = true
            state = .ready
            latestVersion = NuncidBrand.version
            detail = "Verified and ready. Restart now, or it will install when you quit Nuncid."
            return
        }
#endif
        guard startingUpdater, !CommandLine.arguments.dropFirst().contains(where: {
            $0.hasPrefix("--") && ($0.hasSuffix("-probe") || $0.hasSuffix("-self-test") || $0 == "--self-test")
        }) else {
            state = .unavailable
            detail = "Updates are disabled in test runs."
            return
        }
        if let reason = SignedUpdatePolicy.unavailableReason(bundle: .main) {
            state = .unavailable; detail = reason; return
        }
        let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = instance
        instance.automaticallyChecksForUpdates = true
        instance.automaticallyDownloadsUpdates = automaticallyDownloads
        instance.sendsSystemProfile = false
        do {
            try instance.start()
            applySchedule(checkNow: cadence == .developing)
        }
        catch { updater = nil; state = .unavailable; detail = "The updater could not start. Reinstall Nuncid to retry." }
    }

    func toggleDevelopingChecks() {
        let next = cadence.toggled(standard: standardCadence)
        standardCadence = next.standard
        defaults.set(standardCadence.rawValue, forKey: UpdateCheckCadence.standardStorageKey)
        cadence = next.cadence
    }

    private func persistCadence(checkNow: Bool) {
        defaults.set(cadence.rawValue, forKey: UpdateCheckCadence.storageKey)
        if cadence != .developing {
            standardCadence = cadence
            defaults.set(cadence.rawValue, forKey: UpdateCheckCadence.standardStorageKey)
        }
        applySchedule(checkNow: checkNow)
    }

    /// Sparkle's release scheduler will not run faster than once an hour, so
    /// the 5-minute development cadence uses its own timer.
    private func applySchedule(checkNow: Bool) {
        updater?.updateCheckInterval = cadence.interval
        developTimer?.invalidate()
        developTimer = nil
        guard cadence == .developing, updater != nil else { return }
        let timer = Timer(timeInterval: cadence.interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updater?.checkForUpdatesInBackground() }
        }
        RunLoop.main.add(timer, forMode: .common)
        developTimer = timer
        if checkNow { updater?.checkForUpdatesInBackground() }
    }

    func performAction() {
        guard canAct else { return }
        userRequestedCheck = true
        restartRequested = state == .ready
        if let reply = installReply, restartRequested {
            installReply = nil
            state = .installing
            reply(.install)
        } else {
            if !restartRequested { state = .checking }
            updater?.checkForUpdates()
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        let installed = NuncidBrand.versionScheme.flatMap {
            ReleaseIdentity(rawVersion: NuncidBrand.version, scheme: $0, sequence: NuncidBrand.releaseSequence)
        }
        var downloadURL = item.fileURL
#if DEBUG
        // The CI fixture uses an isolated loopback server and a PUBLIC test key.
        // All signature, identity, staging and installation code remains real.
        if integrationProbe, item.fileURL?.host == "127.0.0.1",
           item.fileURL?.path == "/Nuncid-fixture.zip" {
            downloadURL = URL(string: "https://github.com/markus-barta/nuncid/releases/download/v\(item.displayVersionString)/Nuncid-\(item.displayVersionString).zip")
        }
#endif
        guard item.signingValidationStatus == .succeeded,
              SignedUpdatePolicy.identity(description: item.itemDescription, displayVersion: item.displayVersionString,
                                          url: downloadURL, installed: installed) != nil,
              !item.isInformationOnlyUpdate else {
            throw NSError(domain: "Nuncid.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The update's release identity is invalid. Your installed app is unchanged."])
        }
        latestVersion = item.displayVersionString
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        state = .ready
        latestVersion = item.displayVersionString
        detail = "Verified and ready. Restart now, or it will install when you quit Nuncid."
        // As in CodexBar, let Sparkle keep its scheduler/session. A manual check
        // resumes the staged installer; retaining this callback stalls checks.
        return false
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading
        latestVersion = item.displayVersionString
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).domain != SUSparkleErrorDomain || (error as NSError).code != SUError.noUpdateError.rawValue { fail(error) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if state != .ready { state = .current; detail = "No compatible newer update was found." }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A background cycle finishing must not erase a user's pending request
        // to resume its staged update in a new foreground cycle.
        if updateCheck == .updates {
            userRequestedCheck = false
            restartRequested = false
        }
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticallyDownloads, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { if state != .ready { state = .checking } }
    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        latestVersion = appcastItem.displayVersionString
        guard !appcastItem.isInformationOnlyUpdate else { reply(.dismiss); return }
        if updateState.stage == .installing {
            if restartRequested { state = .installing; reply(.install) }
            else {
                state = .ready
                detail = "Verified and ready. Restart now, or it will install when you quit Nuncid."
                reply(.dismiss)
            }
        } else if automaticallyDownloads || userRequestedCheck || updateState.stage == .downloaded {
            state = updateState.stage == .downloaded ? .verifying : .downloading
            reply(.install)
        } else { reply(.dismiss) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if state != .ready { state = .current; detail = "No compatible newer update was found." }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { fail(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { state = .downloading }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { state = .verifying }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if restartRequested { state = .installing; reply(.install) }
        else {
            installReply = reply
            state = .ready
            detail = "Verified and ready. Restart now, or it will install when you quit Nuncid."
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        state = .installing
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { installReply = nil }
    func showUpdateInFocus() {}

    func fail(_ error: Error) {
        let failure = error as NSError
        let checkFailure = failure.domain == NSURLErrorDomain
            || (failure.domain == SUSparkleErrorDomain
                && [Int(SUError.appcastError.rawValue), Int(SUError.appcastParseError.rawValue)].contains(failure.code))
            || failure.domain == "Nuncid.Updates"
        if checkFailure && ![.downloading, .verifying, .installing].contains(state) {
            // A failed feed refresh does not invalidate Sparkle's staged update.
            if state == .ready { return }
            if userRequestedCheck || state == .checking {
                state = .checkFailed
                detail = "Could not check for updates. Try again when you are online."
            }
            // Quiet scheduled checks leave the prior status alone when offline.
            return
        }
        var cause: NSError? = failure
        lastFailureWasValidation = false
        lastFailureCodes = []
        for _ in 0..<8 {
            guard let current = cause else { break }
            lastFailureCodes.append("\(current.domain):\(current.code)")
            // Sparkle 2.10's SUSignatureVerifier reports SUValidationError;
            // older framework paths can still report SUSignatureError.
            if current.domain == SUSparkleErrorDomain &&
                [Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue)].contains(current.code) {
                lastFailureWasValidation = true
            }
            cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        installReply = nil
        restartRequested = false
        state = .failed
        detail = "The update could not be completed. Try again."
    }
}
