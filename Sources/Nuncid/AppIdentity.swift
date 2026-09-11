import Foundation

enum AppIdentity {
    static let bundleIdentifier = "at.markusbarta.nuncid"
    static let legacyPreferencesDomain = "at.markusbarta.glint"
    static let migrationKey = "identity.nuncidMigrationV1"

    /// Only the packaged app migrates. Development tools and visual probes have
    /// separate domains and must never import the user's live configuration.
    static func migratePreferencesIfNeeded() throws {
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return }
        let backupDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nuncid/IdentityMigration", isDirectory: true)
        try migrate(defaults: .standard, sourceDomain: legacyPreferencesDomain,
                    destinationDomain: bundleIdentifier, backupDirectory: backupDirectory)
    }

    static func migrate(defaults: UserDefaults, sourceDomain: String,
                        destinationDomain: String, backupDirectory: URL) throws {
        let destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[migrationKey] == nil else { return }
        let source = defaults.persistentDomain(forName: sourceDomain) ?? [:]
        // Backup precedes any write. Keep both domains intact for rollback;
        // retiring the old installation is a separate, verified operator step.
        if !source.isEmpty {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let backup = backupDirectory.appendingPathComponent("preferences-\(UUID().uuidString).plist")
            let data = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
            try data.write(to: backup, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        // Explicit false, zero and empty values in an existing destination win.
        var merged = source.merging(destination) { _, current in current }
        for key in ["pinnedProject", "lastPPMProject"] where (merged[key] as? String) == "GLINT" {
            merged[key] = "NUNCID"
        }
        merged[migrationKey] = true
        defaults.setPersistentDomain(merged, forName: destinationDomain)
        guard defaults.synchronize(),
              let saved = defaults.persistentDomain(forName: destinationDomain),
              NSDictionary(dictionary: saved).isEqual(to: merged) else {
            // Allow retry without letting a partial migration look complete.
            defaults.setPersistentDomain(destination, forName: destinationDomain)
            defaults.synchronize()
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
