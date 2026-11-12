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
            String(localized: "The following applications failed to quit and were not restarted:") + "\n" + failedApps.joined(separator: "\n")
        }

        var recoverySuggestion: String? {
            String(localized: "You may need to log out for the changes to take effect.")
        }
    }

    /// Maximum time to wait for an app to quit gracefully.
    private let terminationTimeout: Duration = .seconds(5)

    enum SpacingError: LocalizedError {
        case defaultsWriteFailed
        case terminationFailed(app: String)

        var errorDescription: String? {
            switch self {
            case .defaultsWriteFailed:
                String(localized: "The menu bar spacing settings could not be updated.")
            case let .terminationFailed(app):
                String(localized: "The application \(app) did not quit. Quit it manually and try again.")
            }
        }
    }

    /// The offset to apply to the default spacing and padding.
    /// Does not take effect until ``applyOffset()`` is called.
    var offset = 0

    /// Returns the current value for the given key, or `nil` if the key is unset.
    private func currentValue(forKey key: Key) -> Int? {
        let value = CFPreferencesCopyValue(
            key.rawValue as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return (value as? NSNumber)?.intValue
    }

    /// Sets the value for the given key, or removes the key if `value` is `nil`.
    private func setValue(_ value: Int?, forKey key: Key) {
        let propertyList: CFPropertyList? = value.map { NSNumber(value: $0) as CFPropertyList }
        CFPreferencesSetValue(
            key.rawValue as CFString,
            propertyList,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }

    /// Applies the given values to both spacing keys and synchronizes them to disk.
    private func setValues(spacing: Int?, padding: Int?) throws {
        setValue(spacing, forKey: .spacing)
        setValue(padding, forKey: .padding)
        guard CFPreferencesAppSynchronize(kCFPreferencesAnyApplication) else {
            throw SpacingError.defaultsWriteFailed
        }
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
        // Snapshot the current values so they can be restored if writing fails.
        let currentSpacing = currentValue(forKey: .spacing)
        let currentPadding = currentValue(forKey: .padding)
        let proposedSpacing = offset == 0 ? nil : Key.spacing.defaultValue + offset
        let proposedPadding = offset == 0 ? nil : Key.padding.defaultValue + offset

        do {
            try setValues(spacing: proposedSpacing, padding: proposedPadding)
        } catch {
            try? setValues(spacing: currentSpacing, padding: currentPadding)
            throw error
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
