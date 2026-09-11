import Foundation

enum IdentityMigrationChecks {
    static func run() throws {
        let source = "NuncidSelfTests.identity-source.\(UUID().uuidString)"
        let target = "NuncidSelfTests.identity-target.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: target)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: target)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: directory)
        }
        func check(_ condition: Bool) throws {
            if !condition { throw CocoaError(.validationMissingMandatoryProperty) }
        }
        let original: [String: Any] = [
            "inspectHotKey": Data([0, 1, 255]), "pinHotKey": Data([2, 3]),
            "pinnedProject": "GLINT", "lastPPMProject": "GLINT", "pinnedNumber": 78,
            "pinnedOrigin.5": [12.5, 42.0], "inspectionZoomPercent": 130,
            "exploration.refreshOnSourceWindowChanges": false,
            "exploration.markerAppearance.v1": Data([4, 5]),
            "activation.mode": "hold", "popup.restorePinned": true,
            "presentation.textSize": 14, "applicationResolutionHistoryV1": Data([6]),
            "resolutionCacheV1": Data([7]), "future.setting": ["nested": [1, 2]]
        ]
        defaults.setPersistentDomain(original, forName: source)
        defaults.setPersistentDomain(["popup.restorePinned": false, "presentation.textSize": 0,
                                      "activation.mode": ""], forName: target)
        try AppIdentity.migrate(defaults: defaults, sourceDomain: source,
                                destinationDomain: target, backupDirectory: directory)
        var expected = original
        expected["popup.restorePinned"] = false
        expected["presentation.textSize"] = 0
        expected["activation.mode"] = ""
        expected["pinnedProject"] = "NUNCID"
        expected["lastPPMProject"] = "NUNCID"
        expected[AppIdentity.migrationKey] = true
        try check(NSDictionary(dictionary: defaults.persistentDomain(forName: target)!).isEqual(to: expected))
        try check(NSDictionary(dictionary: defaults.persistentDomain(forName: source)!).isEqual(to: original))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try check(backups.count == 1)
        let backup = try PropertyListSerialization.propertyList(from: Data(contentsOf: backups[0]), format: nil) as! [String: Any]
        try check(NSDictionary(dictionary: backup).isEqual(to: original))
        // A reset/deletion after migration must not resurrect stale settings.
        defaults.removeObject(forKey: "inspectHotKey")
        try AppIdentity.migrate(defaults: defaults, sourceDomain: source,
                                destinationDomain: target, backupDirectory: directory)
        try check(defaults.object(forKey: "inspectHotKey") == nil)
        try check(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        // Backup failure must leave the destination untouched and retryable.
        defaults.removePersistentDomain(forName: target)
        do {
            try AppIdentity.migrate(defaults: defaults, sourceDomain: source,
                                    destinationDomain: target, backupDirectory: backups[0])
            throw CocoaError(.validationMissingMandatoryProperty)
        } catch CocoaError.fileWriteFileExists { }
        try check(defaults.persistentDomain(forName: target)?.isEmpty != false)
        defaults.removePersistentDomain(forName: source)
        try AppIdentity.migrate(defaults: defaults, sourceDomain: source,
                                destinationDomain: target, backupDirectory: directory)
        try check(defaults.bool(forKey: AppIdentity.migrationKey))
        try check(ProjectMatcher.bestMatch(for: "glint")?.key == "NUNCID")
        try check(!ProjectDescriptor.selectable.contains { $0.key == "GLINT" })
    }
}
