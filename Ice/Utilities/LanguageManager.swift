//
//  LanguageManager.swift
//  Ice
//

import Cocoa
import OSLog

/// A language that Ice can display its interface in.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    /// The name of the language, written in that language.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }
}

/// Manages the language used by Ice's interface.
@MainActor
enum LanguageManager {
    /// The user default that controls the app's preferred languages.
    private static let appleLanguagesKey = "AppleLanguages"

    /// The language explicitly selected for Ice, or `nil` if Ice follows
    /// the system language.
    static var selectedLanguage: AppLanguage? {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let domain = UserDefaults.standard.persistentDomain(forName: bundleIdentifier),
            let languages = domain[appleLanguagesKey] as? [String],
            let languageCode = languages.first
        else {
            return nil
        }
        return AppLanguage(rawValue: languageCode)
    }

    /// Selects the given language for Ice.
    ///
    /// Passing `nil` makes Ice follow the system language again. The app is
    /// relaunched because localizations are resolved when the bundle loads.
    static func setLanguage(_ language: AppLanguage?) {
        if let language {
            UserDefaults.standard.set([language.rawValue], forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }
        UserDefaults.standard.synchronize()
        relaunch()
    }

    /// Launches a new instance of Ice and terminates the current one.
    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Logger.language.error("Failed to relaunch Ice: \(error)")
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Could not restart Ice.")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                } else {
                    // Give the new instance a moment to finish launching
                    // before the current instance exits.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

// MARK: - Logger

private extension Logger {
    static let language = Logger(category: "Language")
}
