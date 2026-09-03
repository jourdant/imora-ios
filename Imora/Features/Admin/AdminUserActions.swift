import SwiftUI

/// what an admin can do to one account. each case presents its own
/// confirmation, so a screen keeps a single optional as its action state.
nonisolated enum AdminUserAction: Equatable {
    case resetPassword(AdminUser)
    case resetPinCode(AdminUser)
    case delete(AdminUser)
    case restore(AdminUser)

    enum Kind { case resetPassword, resetPinCode, delete, restore }

    var kind: Kind {
        switch self {
        case .resetPassword: .resetPassword
        case .resetPinCode: .resetPinCode
        case .delete: .delete
        case .restore: .restore
        }
    }

    var user: AdminUser {
        switch self {
        case .resetPassword(let user), .resetPinCode(let user), .delete(let user), .restore(let user):
            user
        }
    }
}

/// the menu the web offers per account, shared by the list rows and the
/// detail toolbar. edit and details navigate, everything else hands the
/// host an action to confirm.
struct AdminUserMenuItems: View {
    @Environment(SessionStore.self) private var session

    let user: AdminUser
    var onDetails: (() -> Void)? = nil
    let onEdit: () -> Void
    @Binding var action: AdminUserAction?

    private var isSelf: Bool { session.user?.id == user.id }

    var body: some View {
        if let onDetails {
            Button("Details", systemImage: "info.circle", action: onDetails)
        }
        Button("Edit", systemImage: "pencil", action: onEdit)
        if !isSelf {
            Button("Reset Password", systemImage: "lock.rotation") {
                action = .resetPassword(user)
            }
        }
        Button("Reset PIN Code", systemImage: "lock.shield") {
            action = .resetPinCode(user)
        }
        if user.canRestore {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                action = .restore(user)
            }
        }
        if !isSelf, !user.isDeleted {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                action = .delete(user)
            }
        }
    }
}

/// attaches every confirmation an action needs to the control that raised
/// it. rows and the detail toolbar each apply it for their own user, so a
/// dialog only ever morphs out of the control the finger is on.
struct AdminUserActionPresenter: ViewModifier {
    @Environment(SessionStore.self) private var session

    let user: AdminUser
    @Binding var action: AdminUserAction?
    let onUpdated: (AdminUser) -> Void
    let onFeedback: (String) -> Void

    @State private var generatedPassword: GeneratedPassword?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Reset \(user.name)’s password?",
                isPresented: presented(.resetPassword),
                titleVisibility: .visible
            ) {
                Button("Reset Password") {
                    Task { await resetPassword() }
                }
            } message: {
                Text("A temporary password is generated and the user must change it at their next login.")
            }
            .confirmationDialog(
                "Reset \(user.name)’s PIN code?",
                isPresented: presented(.resetPinCode),
                titleVisibility: .visible
            ) {
                Button("Reset PIN Code", role: .destructive) {
                    Task { await resetPinCode() }
                }
            } message: {
                Text("The locked folder PIN is removed and the user can set up a new one.")
            }
            .confirmationDialog(
                "Restore \(user.name)?",
                isPresented: presented(.restore),
                titleVisibility: .visible
            ) {
                Button("Restore") {
                    Task { await restore() }
                }
            } message: {
                Text("\(user.name)’s account will be restored.")
            }
            .sheet(isPresented: presented(.delete)) {
                AdminUserDeleteSheet(user: user, onDeleted: onUpdated)
            }
            .sheet(item: $generatedPassword) { password in
                PasswordResetSheet(password: password.value)
            }
    }

    private func presented(_ kind: AdminUserAction.Kind) -> Binding<Bool> {
        Binding(
            get: { action?.kind == kind && action?.user.id == user.id },
            set: { presented in
                if !presented, action?.kind == kind, action?.user.id == user.id {
                    action = nil
                }
            }
        )
    }

    // the web generates the temporary password client side too.
    private func resetPassword() async {
        guard let client = session.client else { return }
        let password = AdminPasswordGenerator.make()
        do {
            let updated = try await client.updateAdminUser(id: user.id, fields: [
                "password": AnyEncodable(password),
                "shouldChangePassword": AnyEncodable(true),
            ])
            onUpdated(updated)
            generatedPassword = GeneratedPassword(value: password)
        } catch {
            ErrorToastCenter.shared.show("Couldn’t reset the password", error: error)
        }
    }

    private func resetPinCode() async {
        guard let client = session.client else { return }
        do {
            let updated = try await client.updateAdminUser(id: user.id, fields: [
                "pinCode": AnyEncodable(Optional<String>.none),
            ])
            onUpdated(updated)
            onFeedback("PIN code reset")
        } catch {
            ErrorToastCenter.shared.show("Couldn’t reset the PIN code", error: error)
        }
    }

    private func restore() async {
        guard let client = session.client else { return }
        do {
            let updated = try await client.restoreAdminUser(id: user.id)
            onUpdated(updated)
            onFeedback("User restored")
        } catch {
            ErrorToastCenter.shared.show("Couldn’t restore the user", error: error)
        }
    }
}

extension View {
    func adminUserActions(
        for user: AdminUser,
        action: Binding<AdminUserAction?>,
        onUpdated: @escaping (AdminUser) -> Void,
        onFeedback: @escaping (String) -> Void
    ) -> some View {
        modifier(AdminUserActionPresenter(
            user: user,
            action: action,
            onUpdated: onUpdated,
            onFeedback: onFeedback
        ))
    }
}

private struct GeneratedPassword: Identifiable {
    let value: String
    var id: String { value }
}

/// the web's character set and length, drawn from the system generator.
nonisolated enum AdminPasswordGenerator {
    private static let characters = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ,.-{}+!#$%/()=?")

    static func make(length: Int = 16) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator) ?? "x" })
    }
}

// MARK: - delete

/// queues the account for removal after the server's delay, or with the
/// force switch starts removing right away behind an email confirmation.
private struct AdminUserDeleteSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let user: AdminUser
    let onDeleted: (AdminUser) -> Void

    @State private var force = false
    @State private var typedEmail = ""
    @State private var deleteDelay = 7
    @State private var isDeleting = false

    private var isConfirmed: Bool {
        !force || typedEmail.trimmingCharacters(in: .whitespacesAndNewlines) == user.email
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if force {
                        Text("\(Text(user.name).bold())’s account and assets will be queued for permanent deletion immediately.")
                    } else {
                        Text("\(Text(user.name).bold())’s account and assets will be scheduled for permanent deletion in \(deleteDelay) day\(deleteDelay == 1 ? "" : "s").")
                    }
                }
                Section {
                    Toggle("Queue user and assets for immediate deletion", isOn: $force)
                }
                if force {
                    Section {
                        TextField("Email", text: $typedEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("To confirm, type “\(user.email)” below")
                    } footer: {
                        Text("Warning: this will immediately remove the user and all assets. This cannot be undone and the files cannot be recovered.")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(force ? "Permanently Delete" : "Delete", role: .destructive) {
                        Task { await delete() }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!isConfirmed || isDeleting)
                }
            }
            .navigationTitle("Delete User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(isDeleting)
        }
        .presentationDetents([.medium, .large])
        .task {
            guard let client = session.client,
                  let delay = try? await ImmichClient.publicConfig(apiURL: client.apiURL).userDeleteDelay
            else { return }
            deleteDelay = delay
        }
    }

    private func delete() async {
        guard let client = session.client else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let deleted = try await client.deleteAdminUser(id: user.id, force: force)
            onDeleted(deleted)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show("Couldn’t delete the user", error: error)
        }
    }
}

// MARK: - password reset

/// shows the temporary password once, with a copy button.
private struct PasswordResetSheet: View {
    @Environment(\.dismiss) private var dismiss

    let password: String

    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.green)
                Text("The user’s password has been reset:")
                HStack(spacing: 12) {
                    Text(password)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        UIPasteboard.general.string = password
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel("Copy password")
                }
                Text("Please provide the temporary password to the user and inform them they will need to change the password at their next login.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Password Reset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - feedback

/// a short success line, the album screen's bottom glass pill.
@Observable
final class TransientFeedback {
    private(set) var message: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        hideTask?.cancel()
        message = text
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }
}

private struct FeedbackPillModifier: ViewModifier {
    let feedback: TransientFeedback

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message = feedback.message {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: feedback.message)
    }
}

extension View {
    func feedbackPill(_ feedback: TransientFeedback) -> some View {
        modifier(FeedbackPillModifier(feedback: feedback))
    }
}
