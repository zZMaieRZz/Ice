//
//  HotkeyRecorderModel.swift
//  Ice
//

import Combine
import SwiftUI

@MainActor
final class HotkeyRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false

    @Published var isPresentingError = false

    @Published private(set) var errorTitle = ""

    @Published private(set) var errorMessage = ""

    let hotkey: Hotkey

    private lazy var monitor = LocalEventMonitor(mask: .keyDown) { [weak self] event in
        guard let self else {
            return event
        }
        handleKeyDown(event: event)
        return nil
    }

    private var cancellables = Set<AnyCancellable>()

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        hotkey.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    func startRecording() {
        guard !isRecording else {
            return
        }
        hotkey.disable()
        monitor.start()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else {
            return
        }
        monitor.stop()
        hotkey.enable()
        isRecording = false
    }

    private func handleKeyDown(event: NSEvent) {
        let keyCombination = KeyCombination(event: event)
        guard !keyCombination.modifiers.isEmpty else {
            if keyCombination.key == .escape {
                stopRecording()
            } else {
                NSSound.beep()
            }
            return
        }
        guard keyCombination.modifiers != .shift else {
            NSSound.beep()
            return
        }
        guard !keyCombination.isReservedBySystem else {
            presentError(
                String(localized: "Choose a different shortcut."),
                title: String(localized: "Hotkey is reserved by macOS")
            )
            return
        }

        let shortcut = keyCombination.modifiers.symbolicValue + keyCombination.key.stringValue.capitalized

        if let conflictingHotkey = hotkey.conflictingHotkey(for: keyCombination) {
            presentError(
                String(localized: "\(shortcut) is already used for \"\(conflictingHotkey.action.displayName)\". Choose a different shortcut.")
            )
            return
        }

        let previousKeyCombination = hotkey.keyCombination
        hotkey.keyCombination = keyCombination

        guard hotkey.isEnabled else {
            // The system refused the registration. Restore the previous
            // combination instead of leaving the hotkey in a broken state.
            hotkey.keyCombination = previousKeyCombination
            presentError(
                String(localized: "\(shortcut) is unavailable. Another app may already be using it.")
            )
            return
        }

        stopRecording()
    }

    /// Stops recording and presents an error explaining why the shortcut
    /// could not be used.
    private func presentError(_ message: String, title: String = String(localized: "Hotkey Unavailable")) {
        stopRecording()
        errorTitle = title
        errorMessage = message
        isPresentingError = true
    }
}
