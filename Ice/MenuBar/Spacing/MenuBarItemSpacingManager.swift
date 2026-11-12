//
//  MenuBarItemSpacingManager.swift
//  Ice
//

import Cocoa

/// Manager for menu bar item spacing.
@MainActor
final class MenuBarItemSpacingManager {
    /// UserDefaults keys.
    private enum Key: String {
        case spacing = "NSStatusItemSpacing"
        case padding = "NSStatusItemSelectionPadding"

        /// The default value for the key.
        var defaultValue: Int {
            switch self {
            case .spacing: 16
            case .padding: 16
            }
        }
    }

    /// An error that groups multiple failed app relaunches.
    private struct GroupedRelaunchError: LocalizedError {
        let failedApps: [String]

        var errorDescription: String? {
            "The following applications failed to quit and were not restarted:\n" + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            "You may need to log out for the changes to take effect."
        }
    }

    /// Maximum time to wait for an app to quit gracefully.
    private let terminationTimeout: Duration = .seconds(5)

    private enum SpacingError: LocalizedError {
        case commandFailed(command: String, status: Int32)
        case terminationFailed(app: String)

        var errorDescription: String? {
            switch self {
            case let .commandFailed(command, status):
                "The command \(command) failed with exit status \(status)."
            case let .terminationFailed(app):
                "The application \(app) did not quit. Quit it manually and try again."
            }
        }
    }

    /// The offset to apply to the default spacing and padding.
    /// Does not take effect until ``applyOffset()`` is called.
    var offset = 0

    /// Runs a command with the given arguments.
    private func runCommand(_ command: String, with arguments: [String]) async throws {
        let process = Process()

        process.executableURL = URL(filePath: "/usr/bin/defaults")
        process.arguments = arguments

        let task = Task.detached {
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw SpacingError.commandFailed(command: command, status: process.terminationStatus)
            }
        }

        return try await task.value
    }

    /// Removes the value for the specified key.
    private func removeValue(forKey key: Key) async throws {
        try await runCommand("defaults", with: ["-currentHost", "delete", "-globalDomain", key.rawValue])
    }

    /// Sets the value for the specified key to the key's default value plus the given offset.
    private func setOffset(_ offset: Int, forKey key: Key) async throws {
        try await runCommand("defaults", with: ["-currentHost", "write", "-globalDomain", key.rawValue, "-int", String(key.defaultValue + offset)])
    }

    /// Returns a log string for the given app.
    private nonisolated func logString(for app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "<NIL>"
    }

    /// Asynchronously signals the given app to quit.
    private func signalAppToQuit(_ app: NSRunningApplication) async throws {
        if app.isTerminated {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already terminated")
            return
        } else {
            Logger.spacing.debug("Signaling application \"\(logString(for: app))\" to quit")
        }

        try Task.checkCancellation()
        guard app.terminate() else {
            throw SpacingError.terminationFailed(app: logString(for: app))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: terminationTimeout)
        while !app.isTerminated {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw SpacingError.terminationFailed(app: logString(for: app))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Logger.spacing.debug("Application \"\(logString(for: app))\" terminated successfully")
    }

    /// Asynchronously launches the app at the given URL.
    private nonisolated func launchApp(at applicationURL: URL, bundleIdentifier: String) async throws {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            Logger.spacing.debug("Application \"\(logString(for: app))\" is already open, so skipping launch")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    /// Asynchronously relaunches the given app.
    private func relaunchApp(_ app: NSRunningApplication) async throws {
        struct RelaunchError: Error { }
        guard
            let url = app.bundleURL,
            let bundleIdentifier = app.bundleIdentifier
        else {
            throw RelaunchError()
        }
        try await signalAppToQuit(app)
        if app.isTerminated {
            try await launchApp(at: url, bundleIdentifier: bundleIdentifier)
        } else {
            throw RelaunchError()
        }
    }

    /// Applies the current ``offset``.
    ///
    /// - Note: Calling this restarts all apps with a menu bar item.
    func applyOffset() async throws {
        if offset == 0 {
            try await removeValue(forKey: .spacing)
            try await removeValue(forKey: .padding)
        } else {
            try await setOffset(offset, forKey: .spacing)
            try await setOffset(offset, forKey: .padding)
        }

        try await Task.sleep(for: .milliseconds(100))

        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let pids = Set(items.map { $0.ownerPID })

        var failedApps = [String]()

        await withTaskGroup(of: Void.self) { group in
            for pid in pids {
                guard
                    let app = NSRunningApplication(processIdentifier: pid),
                    app.bundleIdentifier != "com.apple.controlcenter", // ControlCenter handles its own relaunch, so skip it.
                    app != .current
                else {
                    continue
                }
                group.addTask { @MainActor in
                    do {
                        try await self.relaunchApp(app)
                    } catch {
                        guard let name = app.localizedName else {
                            return
                        }
                        if app.bundleIdentifier == "com.apple.Spotlight" {
                            // Spotlight automatically relaunches, so only consider it a failure if it never quit.
                            if
                                let latestSpotlightInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight").first,
                                latestSpotlightInstance.processIdentifier == app.processIdentifier
                            {
                                failedApps.append(name)
                            }
                        } else {
                            failedApps.append(name)
                        }
                    }
                }
            }
        }

        try await Task.sleep(for: .milliseconds(100))

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            do {
                try await signalAppToQuit(app)
            } catch {
                if let name = app.localizedName {
                    failedApps.append(name)
                }
            }
        }

        if !failedApps.isEmpty {
            throw GroupedRelaunchError(failedApps: failedApps)
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let spacing = Logger(category: "Spacing")
}
