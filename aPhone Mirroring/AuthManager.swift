//
//  AuthManager.swift
//  aPhone Mirroring
//
//  Manages biometric / password authentication for the private data tabs
//  (Messages, Photos, Calls). Lock triggers:
//    • Cold launch — always starts locked
//    • App in background for ≥ 2 minutes — locks on next foreground
//    • 2 minutes of inactivity while foregrounded — locks in place
//    • Screen locked / fast-user-switch — locks immediately
//
//  The host view calls handleAppResigned() / handleAppActivated() via
//  NotificationCenter publishers, and userDidInteract() on any tab interaction
//  to keep the inactivity timer alive.
//

import Foundation
import LocalAuthentication

// MARK: - AuthManager

@MainActor
@Observable
final class AuthManager {

    // MARK: - State (read-only outside)

    private(set) var isLocked        = true
    private(set) var isAuthenticating = false

    /// SF Symbol name and label for the primary unlock button.
    private(set) var unlockIcon  = "lock.fill"
    private(set) var unlockLabel = "Unlock"

    // MARK: - Private

    private var inactivityTask: Task<Void, Never>?

    private static let lockDelay: TimeInterval = 120 // 2 minutes

    // MARK: - Init

    init() {
        // Probe biometry type to set button labels once up front.
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            switch ctx.biometryType {
            case .touchID:
                unlockIcon  = "touchid"
                unlockLabel = "Use Touch ID"
            case .faceID:
                unlockIcon  = "faceid"
                unlockLabel = "Use Face ID"
            default:
                unlockIcon  = "lock.open.fill"
                unlockLabel = "Use Password"
            }
        }
    }

    // MARK: - App lifecycle

    func handleAppResigned() {
        cancelInactivityTimer()
        // Lock even while backgrounded after the delay — prevents seeing content in Mission Control
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lockDelay))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    func handleAppActivated() {
        // If background timer already fired, we're locked — leave it
        // If still running, cancel it and restart the inactivity timer normally
        if !isLocked {
            cancelInactivityTimer()
            resetInactivityTimer()
        }
    }

    /// Call on screen-saver / fast-user-switch to lock immediately.
    func handleSessionLock() {
        lock()
    }

    // MARK: - Interaction

    /// Reset the inactivity timer; call on any meaningful user action in protected content.
    func userDidInteract() {
        guard !isLocked else { return }
        resetInactivityTimer()
    }

    // MARK: - Authentication

    func authenticate() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var nsErr: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsErr) else {
            // No auth available on this machine — grant access.
            unlock()
            return
        }

        do {
            let ok = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Access your phone's messages, photos, and calls"
                ) { success, err in
                    if let err { cont.resume(throwing: err) }
                    else       { cont.resume(returning: success) }
                }
            }
            if ok { unlock() }
        } catch {
            // User cancelled or failed — stay locked.
        }
    }

    // MARK: - Lock / unlock helpers

    func lock() {
        isLocked = true
        cancelInactivityTimer()
    }

    private func unlock() {
        isLocked = false
        resetInactivityTimer()
    }

    private func resetInactivityTimer() {
        cancelInactivityTimer()
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lockDelay))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    private func cancelInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }
}
