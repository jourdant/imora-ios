import SwiftUI

/// the web's create and edit user forms. quota is typed in gibibytes and
/// sent as bytes, an empty field meaning unlimited.
struct AdminUserFormSheet: View {
    enum Mode {
        case create
        case edit(AdminUser)
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSaved: (AdminUser) -> Void

    @State private var email: String
    @State private var name: String
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var storageLabel: String
    @State private var quotaText: String
    @State private var shouldChangePassword = true
    @State private var notify = true
    @State private var isAdmin: Bool
    @State private var diskSize: Int64?
    @State private var isSaving = false

    init(mode: Mode, onSaved: @escaping (AdminUser) -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create:
            _email = State(initialValue: "")
            _name = State(initialValue: "")
            _storageLabel = State(initialValue: "")
            _quotaText = State(initialValue: "")
            _isAdmin = State(initialValue: false)
        case .edit(let user):
            _email = State(initialValue: user.email)
            _name = State(initialValue: user.name)
            _storageLabel = State(initialValue: user.storageLabel ?? "")
            _isAdmin = State(initialValue: user.isAdmin)
            if let quota = user.quotaSizeInBytes, quota >= 0 {
                let gib = BinaryByteFormat.gibibytes(from: quota)
                _quotaText = State(initialValue: gib.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
            } else {
                _quotaText = State(initialValue: "")
            }
        }
    }

    private var editedUser: AdminUser? {
        if case .edit(let user) = mode { return user }
        return nil
    }

    private var isEdit: Bool { editedUser != nil }

    private var isSelf: Bool { editedUser?.id == session.user?.id }

    private var passwordRequired: Bool { session.features?.oauth != true }

    private var passwordMismatch: Bool {
        !passwordConfirm.isEmpty && password != passwordConfirm
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// nil is unlimited; a value that does not parse also reads as unlimited,
    /// which is what an empty number field does on the web.
    private var quotaBytes: Int64? {
        let raw = quotaText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !raw.isEmpty, let value = Double(raw), value >= 0 else { return nil }
        return BinaryByteFormat.bytes(fromGibibytes: value)
    }

    private var quotaExceedsDisk: Bool {
        guard let quotaBytes, let diskSize, quotaBytes > diskSize else { return false }
        // the web only warns about a quota the admin is changing.
        if let editedUser, editedUser.quotaSizeInBytes == quotaBytes { return false }
        return true
    }

    private var canSubmit: Bool {
        guard !isSaving, !trimmedEmail.isEmpty, !trimmedName.isEmpty, !passwordMismatch else { return false }
        if isEdit { return true }
        return !passwordRequired || (!password.isEmpty && password == passwordConfirm)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("admin-user-email")
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .accessibilityIdentifier("admin-user-name")
                }

                if !isEdit {
                    passwordSection
                    Section {
                        Toggle("Require password change on first login", isOn: $shouldChangePassword)
                        if session.features?.email == true {
                            Toggle("Send welcome email", isOn: $notify)
                        }
                    }
                }

                Section {
                    TextField("Unlimited", text: $quotaText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("admin-user-quota")
                } header: {
                    Text("Quota Size (GiB)")
                } footer: {
                    if quotaExceedsDisk {
                        Text("You have set a quota higher than the disk size.")
                            .foregroundStyle(.red)
                    }
                }

                if isEdit {
                    Section {
                        TextField("Storage label", text: $storageLabel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Storage Label")
                    } footer: {
                        Text("To apply the storage label to previously uploaded assets, run the Storage Template Migration job from Job Queues.")
                    }
                }

                if !isSelf {
                    Section {
                        Toggle("Admin User", isOn: $isAdmin)
                    }
                }
            }
            .navigationTitle(isEdit ? "Edit User" : "Create User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? "Save" : "Create") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("admin-user-submit")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .task {
            diskSize = try? await session.client?.serverStorage().diskSizeRaw
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField("Password", text: $password)
                .textContentType(.newPassword)
            SecureField("Confirm password", text: $passwordConfirm)
                .textContentType(.newPassword)
        } footer: {
            if passwordMismatch {
                Text("Passwords do not match.")
                    .foregroundStyle(.red)
            } else if !passwordRequired {
                Text("Optional: this server signs users in through OAuth.")
            }
        }
    }

    private func submit() async {
        guard let client = session.client, canSubmit else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: AdminUser
            if let editedUser {
                saved = try await client.updateAdminUser(id: editedUser.id, fields: editFields())
            } else {
                saved = try await client.createAdminUser(createFields())
            }
            onSaved(saved)
            dismiss()
        } catch {
            ErrorToastCenter.shared.show(isEdit ? "Couldn’t update the user" : "Couldn’t create the user", error: error)
        }
    }

    private func quotaField() -> AnyEncodable {
        if let quotaBytes { return AnyEncodable(quotaBytes) }
        return AnyEncodable(Optional<Int64>.none)
    }

    private func editFields() -> [String: AnyEncodable] {
        let label = storageLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "email": AnyEncodable(trimmedEmail),
            "name": AnyEncodable(trimmedName),
            "storageLabel": label.isEmpty ? AnyEncodable(Optional<String>.none) : AnyEncodable(label),
            "quotaSizeInBytes": quotaField(),
            "isAdmin": AnyEncodable(isAdmin),
        ]
    }

    private func createFields() -> [String: AnyEncodable] {
        [
            "email": AnyEncodable(trimmedEmail),
            "name": AnyEncodable(trimmedName),
            "password": AnyEncodable(password),
            "shouldChangePassword": AnyEncodable(shouldChangePassword),
            "notify": AnyEncodable(notify),
            "isAdmin": AnyEncodable(isAdmin),
            "quotaSizeInBytes": quotaField(),
        ]
    }
}
