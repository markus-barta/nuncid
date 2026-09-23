import Foundation

enum DeveloperMode {
    static let key = "developer.enabled"
    static func enabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
}

enum UpdateSchedule {
    static func visible(developerMode: Bool) -> [UpdateCheckCadence] {
        developerMode ? [.weekly, .daily, .hourly, .developing] : [.weekly, .daily]
    }

    static func afterDisablingDeveloper(_ cadence: UpdateCheckCadence) -> UpdateCheckCadence {
        cadence.isTestingOnly ? .daily : cadence
    }
}

enum DeveloperLogPolicy {
    static func decision(token: String, reason: String, used: Bool) -> String {
        "\(token) · \(used ? "used" : "dropped") · \(reason)"
    }

    static func sanitized(_ raw: String) -> String {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.range(of: #"(?i)\b(gh[pousr]_|github_pat_|bearer\s+|api[_ -]?key|token=)"#, options: .regularExpression) != nil {
            return "Credential omitted."
        }
        return String(trimmed.prefix(180))
    }
}

@MainActor final class DeveloperLog: ObservableObject {
    static let shared = DeveloperLog()
    @Published private(set) var decisions: [String] = []
    @Published private(set) var errors: [String] = []

    func recordDecision(token: String, reason: String, used: Bool) {
        guard DeveloperMode.enabled() else { return }
        let line = DeveloperLogPolicy.decision(token: token, reason: reason, used: used)
        guard decisions.last != line else { return }
        decisions.append(line)
        if decisions.count > 24 { decisions.removeFirst(decisions.count - 24) }
    }

    func recordError(_ raw: String) {
        guard DeveloperMode.enabled() else { return }
        let line = DeveloperLogPolicy.sanitized(raw)
        guard !line.isEmpty, errors.last != line else { return }
        errors.append(line)
        if errors.count > 16 { errors.removeFirst(errors.count - 16) }
    }

    func clear() {
        decisions = []
        errors = []
    }
}

struct DeveloperToolReport: Equatable {
    var paimos = "Not found"
    var profiles = "None configured"
    var gitHub = "Not found"
}

enum DeveloperTools {
    static func report() async -> DeveloperToolReport {
        var report = DeveloperToolReport()
        if let paimos = ToolLookup.url(named: "paimos") {
            report.paimos = "Installed · \(paimos.path)"
        }
        let profiles = TrackerDirectory.shared.connections.map(\.id)
        if !profiles.isEmpty { report.profiles = profiles.joined(separator: ", ") }
        if let gh = ToolLookup.url(named: "gh") {
            let signedIn = await ToolLookup.succeeded(gh, ["auth", "status"])
            report.gitHub = signedIn ? "Installed · signed in" : "Installed · not signed in"
        }
        return report
    }
}

enum ToolLookup {
    static func url(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.nix-profile/bin/\(name)", "/etc/profiles/per-user/\(NSUserName())/bin/\(name)", "/run/current-system/sw/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    static func succeeded(_ executable: URL, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: false)
                    return
                }
                let deadline = Date().addingTimeInterval(4)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { process.terminate() }
                continuation.resume(returning: !process.isRunning && process.terminationStatus == 0)
            }
        }
    }
}
