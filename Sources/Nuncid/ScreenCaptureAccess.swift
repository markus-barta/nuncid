import CoreGraphics
import Foundation

/// What a window-list entry says about its title. macOS omits `kCGWindowName`
/// for other apps when Screen Recording is not actually granted, including when
/// System Settings still shows the switch on after the binary changes.
enum ScreenCaptureWindowName: Equatable {
    case absent
    case empty
    case titled
}

struct ScreenCaptureWindowRecord: Equatable {
    var ownerPID: Int32
    var layer: Int
    var name: ScreenCaptureWindowName
}

/// `CGPreflightScreenCaptureAccess` only reports the stored switch. After an
/// update the switch can stay on while the new binary's code directory hash is
/// not the one macOS authorized, so captures of other apps come back empty.
enum ScreenRecordingAccess: Equatable {
    case missing
    case ready
    case stale
    case unconfirmed
}

enum ScreenCaptureAccessPolicy {
    static func verdict(
        preflightGranted: Bool,
        windows: [ScreenCaptureWindowRecord],
        ownPID: Int32
    ) -> ScreenRecordingAccess {
        guard preflightGranted else { return .missing }
        let foreign = windows.filter { $0.ownerPID > 0 && $0.ownerPID != ownPID && $0.layer == 0 }
        if foreign.contains(where: { $0.name == .titled }) { return .ready }
        if foreign.contains(where: { $0.name == .absent }) { return .stale }
        if foreign.isEmpty { return .unconfirmed }
        return .ready
    }
}

enum ScreenCaptureAccessProbe {
    static func currentWindows() -> [ScreenCaptureWindowRecord] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return infos.map { info in
            let name: ScreenCaptureWindowName
            if let value = info[kCGWindowName as String] as? String {
                name = value.isEmpty ? .empty : .titled
            } else {
                name = .absent
            }
            return ScreenCaptureWindowRecord(
                ownerPID: info[kCGWindowOwnerPID as String] as? pid_t ?? -1,
                layer: info[kCGWindowLayer as String] as? Int ?? -1,
                name: name
            )
        }
    }
}

enum ScreenRecordingApprovalReset {
    enum Outcome: Equatable, Sendable {
        case removed
        case failed
    }

    static func arguments(bundleIdentifier: String) -> [String] {
        ["reset", "ScreenCapture", bundleIdentifier]
    }

    static func run(bundleIdentifier: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments(bundleIdentifier: bundleIdentifier)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .removed : .failed
        } catch {
            return .failed
        }
    }
}

enum ScreenRecordingAccessCopy {
    static func settingsTitle(access: ScreenRecordingAccess, restartRequired: Bool) -> String {
        switch access {
        case .stale: return "Screen Recording needs to be allowed again"
        case .missing: return "Allow Screen Recording"
        case .ready, .unconfirmed:
            return restartRequired ? "Restart to finish setup" : "Screen Recording is allowed"
        }
    }

    static func settingsDetail(access: ScreenRecordingAccess, restartRequired: Bool) -> String {
        switch access {
        case .stale:
            return "macOS still shows Nuncid as allowed, but this version can’t read other windows. Remove Nuncid from Screen Recording, add it again, then restart."
        case .missing, .ready, .unconfirmed:
            return restartRequired || access == .missing
                ? "Open settings, drag Nuncid into the list, enable it, then restart."
                : "Nuncid is ready to recognize references on your screen."
        }
    }
}

enum ScreenRecordingVerification: Equatable {
    case confirmed
    case needAnotherWindow

    var message: String {
        switch self {
        case .confirmed: return "Access confirmed."
        case .needAnotherWindow: return "Open another app’s window, then verify again."
        }
    }
}
