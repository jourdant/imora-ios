import SwiftUI

/// the locked folder behind its gate. the session decides whether the grid
/// may show; a gate view finishing its own reveal keeps the stage until it
/// hands over, so the opened lock and the biometric offer get their moment.
struct LockedFolderScreen: View {
    @Environment(SessionStore.self) private var session

    private enum Stage: Equatable {
        case checking
        case unsupported
        case setup
        case entry
        case grid
    }

    @State private var stage: Stage = .checking
    @State private var offersBiometrics = false
    @State private var verifiedPin: String?

    var body: some View {
        if let locked = session.lockedFolder {
            content(locked)
        } else {
            ProgressView()
        }
    }

    private func content(_ locked: LockedFolderSession) -> some View {
        Group {
            switch stage {
            case .grid:
                timeline(locked)
            default:
                gate(locked)
                    .navigationTitle("Locked Folder")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        // restarts on every re-appearance: the pop locked the session, so
        // coming back always re-reads the server.
        .task { await locked.refreshStatus() }
        .onChange(of: locked.phase, initial: true) { _, phase in
            syncStage(with: phase)
        }
        .onAppear { locked.setScreenVisible(true) }
        .onDisappear {
            locked.setScreenVisible(false)
            locked.lock()
        }
        .alert("Unlock with \(LockedPinStore.biometryName) next time?", isPresented: $offersBiometrics) {
            Button("Enable") {
                if let verifiedPin {
                    do {
                        try locked.enableBiometrics(pin: verifiedPin)
                    } catch {
                        ErrorToastCenter.shared.show("Couldn’t enable \(LockedPinStore.biometryName)", error: error)
                    }
                }
                verifiedPin = nil
                stage = .grid
            }
            Button("Not Now", role: .cancel) {
                locked.declineBiometricOffer()
                verifiedPin = nil
                stage = .grid
            }
        } message: {
            Text("Your PIN stays in the keychain and is only released after \(LockedPinStore.biometryName) succeeds.")
        }
    }

    @ViewBuilder private func gate(_ locked: LockedFolderSession) -> some View {
        switch stage {
        case .checking, .grid:
            ProgressView()
        case .unsupported:
            ContentUnavailableView(
                "Locked Folder Unavailable",
                systemImage: "lock.slash",
                description: Text("This server does not support the locked folder yet.")
            )
        case .setup:
            PinSetupView(mode: .setup) { _, pin in
                try await locked.setupPin(pin)
                finishGate(locked, pin: pin)
            }
        case .entry:
            PinEntryView(session: locked) { pin in
                finishGate(locked, pin: pin)
            }
        }
    }

    /// no lock button: leaving the screen locks on its own.
    private func timeline(_ locked: LockedFolderSession) -> some View {
        TimelineScreen(
            title: "Locked Folder",
            filter: TimelineFilter(visibility: .locked),
            emptyIcon: "lock",
            emptyMessage: "Locked folder is empty",
            showsLargeTitle: false,
            onUnauthorized: { locked.noteElevationRejected() }
        )
    }

    private func syncStage(with phase: LockedFolderSession.Phase) {
        switch phase {
        case .unknown: stage = .checking
        case .unsupported: stage = .unsupported
        case .needsSetup: stage = .setup
        case .locked: stage = .entry
        case .unlocked:
            // a gate view finishing its own reveal keeps the stage until then.
            if stage == .checking { stage = .grid }
        }
    }

    /// an empty pin means biometrics opened the folder, so there is nothing
    /// left to offer.
    private func finishGate(_ locked: LockedFolderSession, pin: String) {
        // a lock that landed during the reveal already put the gate back.
        guard locked.isUnlocked else { return }
        if !pin.isEmpty, locked.biometricOfferPending {
            verifiedPin = pin
            offersBiometrics = true
        } else {
            stage = .grid
        }
    }
}
