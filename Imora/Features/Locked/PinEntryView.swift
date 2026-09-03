import LocalAuthentication
import SwiftUI

/// the pin gate. unlock mode opens the folder, verify mode proves the pin
/// for settings. either way the verified pin is handed back after a short
/// dwell on the opened lock.
struct PinEntryView: View {
    enum Mode {
        case unlock
        case verify
    }

    let session: LockedFolderSession
    var mode: Mode = .unlock
    let onVerified: (String) -> Void

    @State private var code = ""
    @State private var attempt = 0
    @State private var isSubmitting = false
    @State private var isVerified = false
    @State private var triedBiometrics = false

    private var biometryName: String { LockedPinStore.biometryName }

    private var biometrySymbol: String {
        switch LockedPinStore.biometryType {
        case .touchID: "touchid"
        case .opticID: "opticid"
        default: "faceid"
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: isVerified ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(isVerified ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.25), value: isVerified)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Enter PIN")
                    .font(.title2.weight(.semibold))
                Text(mode == .unlock
                    ? "Your PIN opens the locked folder."
                    : "Confirm your PIN to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PinCodeField(code: $code, attempt: attempt, isDisabled: isSubmitting || isVerified) { pin in
                Task { await submit(pin) }
            }

            if mode == .unlock, session.biometricsEnabled {
                Button {
                    Task { await unlockWithBiometrics() }
                } label: {
                    Label("Use \(biometryName)", systemImage: biometrySymbol)
                }
                .buttonStyle(.glass)
                .disabled(isSubmitting || isVerified)
                .accessibilityIdentifier("locked-folder-biometrics")
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.success, trigger: isVerified) { _, new in new }
        // a lock landing mid-reveal, the expiry say, puts the field back.
        .onChange(of: session.phase) { _, phase in
            guard phase == .locked, isVerified else { return }
            isVerified = false
            code = ""
        }
        // the folder opens on its own when the pin is stored, like the
        // official mobile client; a refusal just leaves the field.
        .task {
            guard mode == .unlock, session.biometricsEnabled, !triedBiometrics else { return }
            triedBiometrics = true
            await unlockWithBiometrics()
        }
    }

    private func submit(_ pin: String) async {
        guard !isSubmitting, !isVerified else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await session.unlock(pin: pin)
            await finish(with: pin)
        } catch ImmichError.http(let status, _) where (400..<500).contains(status) {
            attempt += 1
            code = ""
        } catch {
            attempt += 1
            code = ""
            ErrorToastCenter.shared.show("Couldn’t unlock the locked folder", error: error)
        }
    }

    private func unlockWithBiometrics() async {
        guard !isSubmitting, !isVerified else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        switch await session.unlockWithBiometrics() {
        case .unlocked:
            // the stored pin is not exposed to the caller; the verified
            // value only matters for enrolling, which is already done.
            await finish(with: "")
        case .cancelled, .fallback:
            break
        }
    }

    private func finish(with pin: String) async {
        isVerified = true
        try? await Task.sleep(for: .milliseconds(450))
        onVerified(pin)
    }
}
