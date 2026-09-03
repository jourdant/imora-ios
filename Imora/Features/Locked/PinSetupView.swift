import SwiftUI

/// creates or changes the pin with one field stepped through the entries:
/// the current pin when changing, then the new one twice.
struct PinSetupView: View {
    enum Mode {
        case setup
        case change
    }

    private enum Step {
        case current
        case new
        case confirm
    }

    let mode: Mode
    let onSubmit: (_ current: String?, _ new: String) async throws -> Void

    @State private var step: Step
    @State private var code = ""
    @State private var attempt = 0
    @State private var currentPin: String?
    @State private var newPin: String?
    @State private var isSubmitting = false
    @State private var isDone = false

    init(mode: Mode, onSubmit: @escaping (_ current: String?, _ new: String) async throws -> Void) {
        self.mode = mode
        self.onSubmit = onSubmit
        _step = State(initialValue: mode == .change ? .current : .new)
    }

    private var title: String {
        switch step {
        case .current: "Enter Current PIN"
        case .new: mode == .change ? "Enter New PIN" : "Create a PIN"
        case .confirm: "Confirm PIN"
        }
    }

    private var subtitle: String {
        switch step {
        case .current: "Your current PIN comes first."
        case .new: "Six digits that open the locked folder."
        case .confirm: "Enter the same PIN again."
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: isDone ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(isDone ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.25), value: isDone)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .animation(.snappy(duration: 0.2), value: step)

            PinCodeField(code: $code, attempt: attempt, isDisabled: isSubmitting || isDone) { pin in
                advance(with: pin)
            }

            Text("The PIN is stored on your Immich server and protects the locked folder on every device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.success, trigger: isDone) { _, new in new }
    }

    private func advance(with pin: String) {
        switch step {
        case .current:
            currentPin = pin
            code = ""
            step = .new
        case .new:
            newPin = pin
            code = ""
            step = .confirm
        case .confirm:
            guard pin == newPin else {
                Task { await restart(at: .new) }
                return
            }
            Task { await submit(pin) }
        }
    }

    /// a wrong entry shakes where it happened before the step moves back.
    private func restart(at target: Step) async {
        attempt += 1
        code = ""
        try? await Task.sleep(for: .milliseconds(450))
        newPin = nil
        if target == .current { currentPin = nil }
        step = target
    }

    private func submit(_ pin: String) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await onSubmit(currentPin, pin)
            isDone = true
        } catch {
            ErrorToastCenter.shared.show(
                mode == .change ? "Couldn’t change the PIN" : "Couldn’t set up the PIN",
                error: error
            )
            await restart(at: mode == .change ? .current : .new)
        }
    }
}
