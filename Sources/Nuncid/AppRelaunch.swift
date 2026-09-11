import AppKit
import Darwin

/// A second invocation of this exact executable waits for the old process to
/// exit before asking Launch Services to reopen this exact app bundle.
@MainActor enum AppRelaunch {
    static let helperFlag = "--relaunch-after-exit"

    nonisolated static func bundleURL(_ bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.standardizedFileURL
        guard url.pathExtension == "app", bundle.bundleIdentifier == AppIdentity.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url
    }

    static func runHelperIfRequested() -> Bool {
        guard CommandLine.arguments.contains(helperFlag) else { return false }
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == helperFlag,
              let parent = Int32(CommandLine.arguments[2]), parent > 1,
              parent == getppid(), let app = bundleURL() else { Darwin.exit(2) }
        // Signal readiness only after validating the parent and launch target.
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        let deadline = Date().addingTimeInterval(20)
        while kill(parent, 0) == 0 {
            guard Date() < deadline else { Darwin.exit(3) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", app.path]
        do {
            try opener.run()
            opener.waitUntilExit()
            guard opener.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        } catch {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Nuncid couldn’t reopen"
            alert.informativeText = "Your settings are saved. Open Nuncid again from its installation folder."
            alert.addButton(withTitle: "Show Nuncid")
            alert.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([app])
            Darwin.exit(4)
        }
        Darwin.exit(0)
    }
}

@MainActor final class PermissionRestarter {
    private var helper: Process?
    private var pipe: Pipe?
    private var timeout: DispatchWorkItem?

    func restart(onFailure: @escaping (String) -> Void) {
        guard helper == nil else { return }
        guard AppRelaunch.bundleURL() != nil, let executable = Bundle.main.executableURL else {
            onFailure("Open the installed Nuncid.app to restart automatically."); return
        }
        guard UserDefaults.standard.synchronize() else {
            onFailure("Your settings couldn’t be saved. Please try again before quitting."); return
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [AppRelaunch.helperFlag, String(getpid())]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        helper = process; pipe = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.helper === process else { return }
                if String(data: data, encoding: .utf8) == "ready\n" {
                    self.timeout?.cancel(); self.timeout = nil
                    handle.readabilityHandler = nil
                    NSApp.terminate(nil)
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.helper === process else { return }
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            self.helper = nil; self.pipe = nil
            onFailure("Restart couldn’t be prepared. Nuncid is still open; please try again.")
        }
        self.timeout = timeout
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        } catch {
            timeout.perform()
        }
    }
}
