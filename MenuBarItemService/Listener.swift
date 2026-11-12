//
//  Listener.swift
//  MenuBarItemService
//

import OSLog
import XPC

/// A wrapper around an XPC listener object.
final class Listener {
    /// The shared listener.
    static let shared = Listener()

    /// The service name.
    private let name = MenuBarItemService.name

    /// The underlying XPC listener object.
    private var listener: XPCListener?

    /// Creates the shared listener.
    private init() { }

    deinit {
        cancel()
    }

    /// Handles a received message.
    private func handleMessage(_ message: XPCReceivedMessage) -> MenuBarItemService.Response? {
        do {
            let request = try message.decode(as: MenuBarItemService.Request.self)
            switch request {
            case .start:
                Logger.default.debug("Listener received start request")
                return .start
            case .sourcePID(let window):
                let pid = SourcePIDCache.shared.pid(for: window)
                return .sourcePID(pid)
            }
        } catch {
            Logger.default.error("Listener failed to handle message with error \(error)")
            return nil
        }
    }

    /// Activates the listener for local ad-hoc builds, accepting clients
    /// that carry the local XPC entitlement. Ad-hoc signatures have no team
    /// identifier, so the upstream `.isFromSameTeam()` requirement cannot be used.
    @available(macOS 26.0, *)
    private func uncheckedActivateWithLocalEntitlement() throws {
        listener = try XPCListener(
            service: name,
            requirement: .hasEntitlement("com.apple.security.get-task-allow")
        ) { [weak self] request in
            request.accept { message in
                self?.handleMessage(message)
            }
        }
    }

    /// Activates the listener without checking if it is already active.
    private func uncheckedActivate() throws {
        listener = try XPCListener(service: name) { [weak self] request in
            request.accept { message in
                self?.handleMessage(message)
            }
        }
    }

    /// Activates the listener.
    func activate() {
        guard listener == nil else {
            Logger.default.notice("Listener is already active")
            return
        }

        Logger.default.debug("Activating listener")

        do {
            if #available(macOS 26.0, *) {
                try uncheckedActivateWithLocalEntitlement()
            } else {
                try uncheckedActivate()
            }
        } catch {
            Logger.default.error("Failed to activate listener with error \(error)")
        }
    }

    /// Cancels the listener.
    func cancel() {
        Logger.default.debug("Canceling listener")
        listener.take()?.cancel()
    }
}
