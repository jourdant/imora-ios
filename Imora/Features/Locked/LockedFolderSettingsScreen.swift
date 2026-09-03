import SwiftUI

/// pin lifecycle and biometric unlock for the locked folder. the pin itself
/// lives on the server; only the biometric copy is on this device.
struct LockedFolderSettingsScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var showsPinSheet = false
    @State private var showsVerifySheet = false
    @State private var showsResetSheet = false

    private var biometryName: String { LockedPinStore.biometryName }

    var body: some View {
        List {
            if let locked = session.lockedFolder {
                if locked.phase == .unsupported {
                    Section {
                        Text("This server does not support the locked folder yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    pinSection(locked)
                    if locked.hasPin, LockedPinStore.biometryType != nil {
                        biometricsSection(locked)
                    }
                    if locked.hasPin {
                        resetSection
                    }
                }
            }
        }
        .navigationTitle("Locked Folder")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.lockedFolder?.refreshStatus() }
        .sheet(isPresented: $showsPinSheet) {
            if let locked = session.lockedFolder {
                pinSheet(locked)
            }
        }
        .sheet(isPresented: $showsVerifySheet) {
            if let locked = session.lockedFolder {
                verifySheet(locked)
            }
        }
        .sheet(isPresented: $showsResetSheet) {
            if let locked = session.lockedFolder {
                PinResetSheet(locked: locked)
            }
        }
    }

    private func pinSection(_ locked: LockedFolderSession) -> some View {
        Section {
            LabeledContent("PIN") {
                Text(locked.hasPin ? "Set" : "Not Set")
            }
            Button(locked.hasPin ? "Change PIN" : "Set Up PIN") {
                showsPinSheet = true
            }
            .accessibilityIdentifier("locked-folder-pin")
        } footer: {
            Text("The PIN is stored on your Immich server and protects the locked folder on every device.")
        }
    }

    private func biometricsSection(_ locked: LockedFolderSession) -> some View {
        Section {
            Toggle("Unlock with \(biometryName)", isOn: Binding(
                get: { locked.biometricsEnabled },
                set: { enabled in
                    if enabled {
                        showsVerifySheet = true
                    } else {
                        locked.disableBiometrics()
                    }
                }
            ))
        } footer: {
            Text("Your PIN stays in the keychain and is only released after \(biometryName) succeeds.")
        }
    }

    private var resetSection: some View {
        Section {
            if session.features?.passwordLogin == true {
                Button("Reset PIN", role: .destructive) {
                    showsResetSheet = true
                }
                .accessibilityIdentifier("locked-folder-reset")
            }
        } footer: {
            Text(session.features?.passwordLogin == true
                ? "Forgot your PIN? Confirm your account password to remove it, then set up a new one."
                : "Your account signs in without a password, so a forgotten PIN can only be reset by a server administrator.")
        }
    }

    private func pinSheet(_ locked: LockedFolderSession) -> some View {
        NavigationStack {
            PinSetupView(mode: locked.hasPin ? .change : .setup) { current, new in
                if let current {
                    try await locked.changePin(current: current, new: new)
                } else {
                    // setup opens the folder with the new pin; settings is
                    // not the folder, so it closes right back.
                    try await locked.setupPin(new)
                    locked.lock()
                }
                try? await Task.sleep(for: .milliseconds(450))
                showsPinSheet = false
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsPinSheet = false }
                }
            }
        }
    }

    private func verifySheet(_ locked: LockedFolderSession) -> some View {
        NavigationStack {
            PinEntryView(session: locked, mode: .verify) { pin in
                do {
                    try locked.enableBiometrics(pin: pin)
                } catch {
                    ErrorToastCenter.shared.show("Couldn’t enable \(biometryName)", error: error)
                }
                // verifying elevated the session; nothing is on screen to
                // keep it that way.
                locked.lock()
                showsVerifySheet = false
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsVerifySheet = false }
                }
            }
        }
    }
}

/// removes the pin with the account password, for when it is forgotten.
private struct PinResetSheet: View {
    let locked: LockedFolderSession
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Account password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("The PIN is removed from your Immich server. Photos stay in the locked folder until you set up a new one.")
                }
                Section {
                    Button("Reset PIN", role: .destructive) {
                        Task { await reset() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(password.isEmpty || isSubmitting)
                }
            }
            .navigationTitle("Reset PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reset() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await locked.resetPin(password: password)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show("Couldn’t reset the PIN", error: error)
        }
    }
}
