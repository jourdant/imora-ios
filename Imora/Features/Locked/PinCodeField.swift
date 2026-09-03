import SwiftUI

/// six digit code entry in the passcode style: boxes fill as the hidden
/// number pad field takes digits, and the sixth one submits.
struct PinCodeField: View {
    static let length = 6

    @Binding var code: String
    /// bumped by the parent on a wrong code: shakes and buzzes. the parent
    /// clears the code itself.
    var attempt = 0
    var isDisabled = false
    let onComplete: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var shakeOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { .rect(cornerRadius: 14, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<Self.length, id: \.self) { index in
                shape
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 44, height: 52)
                    .overlay {
                        if index < code.count {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 12, height: 12)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
            }
        }
        .animation(.snappy(duration: 0.15), value: code.count)
        .offset(x: shakeOffset)
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .background {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityHidden(true)
        }
        .sensoryFeedback(.error, trigger: attempt) { _, new in new > 0 }
        .disabled(isDisabled)
        .onChange(of: code) { _, value in
            let digits = String(value.filter(\.isNumber).prefix(Self.length))
            if digits != value {
                code = digits
                return
            }
            if digits.count == Self.length { onComplete(digits) }
        }
        .onChange(of: attempt) { _, new in
            guard new > 0 else { return }
            Task { await shake() }
        }
        .onAppear { isFocused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(code.count) of \(Self.length) digits entered")
    }

    private func shake() async {
        guard !reduceMotion else { return }
        for offset in [-10.0, 10, -8, 6, 0] {
            withAnimation(.linear(duration: 0.06)) { shakeOffset = offset }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
}
