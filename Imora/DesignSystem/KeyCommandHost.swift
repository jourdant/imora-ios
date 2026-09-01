import SwiftUI
import UIKit

/// one hardware keyboard shortcut for a screen: what the discoverability
/// overlay calls it, the key it answers to and what it does.
struct KeyCommandBinding {
    let title: String
    let input: String
    var modifiers: UIKeyModifierFlags = []
    let action: () -> Void
}

/// installs uikit key commands behind a swiftui screen. a hidden responder
/// takes first responder while the host is active, so the shortcuts work the
/// same in a swiftui cover and in a uikit-presented controller, and they
/// yield to any text field that takes the keyboard.
struct KeyCommandHost: UIViewRepresentable {
    let isActive: Bool
    let commands: [KeyCommandBinding]

    func makeUIView(context: Context) -> KeyCommandResponderView {
        let view = KeyCommandResponderView()
        view.isUserInteractionEnabled = false
        view.commands = commands
        view.isActive = isActive
        return view
    }

    func updateUIView(_ uiView: KeyCommandResponderView, context: Context) {
        uiView.commands = commands
        uiView.isActive = isActive
        // a sheet that had the keyboard is gone by the update that follows
        // its dismissal, which is when the shortcuts come back.
        uiView.claimKeyboardIfFree()
    }
}

final class KeyCommandResponderView: UIView {
    var commands: [KeyCommandBinding] = []
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                claimKeyboardIfFree()
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }
    }

    override var canBecomeFirstResponder: Bool { isActive }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        claimKeyboardIfFree()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard isActive else { return nil }
        return commands.map { binding in
            let command = UIKeyCommand(
                title: binding.title,
                action: #selector(runKeyCommand(_:)),
                input: binding.input,
                modifierFlags: binding.modifiers
            )
            // arrows would otherwise move the system focus ring instead.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func runKeyCommand(_ command: UIKeyCommand) {
        let binding = commands.first {
            $0.input == command.input && $0.modifiers == command.modifierFlags
        }
        binding?.action()
    }

    /// becomes first responder unless something typing-related already is.
    func claimKeyboardIfFree() {
        guard isActive, window != nil, !isFirstResponder else { return }
        if UIResponder.currentFirstResponder is any UITextInput { return }
        becomeFirstResponder()
    }
}

extension UIResponder {
    private static weak var trapped: UIResponder?

    /// the first responder, found by sending an action to nil: uikit hands
    /// it to the first responder, which records itself here.
    static var currentFirstResponder: UIResponder? {
        trapped = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.trapFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        return trapped
    }

    @objc private func trapFirstResponder() {
        UIResponder.trapped = self
    }
}
