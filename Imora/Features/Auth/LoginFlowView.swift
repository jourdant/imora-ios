import SwiftUI

/// interactive tint for the auth screen, the deepest hue of the app mark.
private let brandTint = Color(.brandTint)

struct LoginFlowView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    private enum Step: Equatable {
        case server
        case credentials(URL)
    }

    @State private var step: Step = .server
    @State private var serverInput = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var features: ServerFeatures?
    @State private var config: ServerConfig?
    @State private var oauthAutoLaunched = false
    @FocusState private var focus: AuthFocus?

    var body: some View {
        // the reader is only there to keep the card centred while it still
        // fits, and let it scroll once the keyboard eats the height.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 40)

                    VStack(spacing: 14) {
                        switch step {
                        case .server:
                            serverForm
                        case .credentials:
                            credentialsForm
                        }
                    }
                    .animation(.smooth(duration: 0.3), value: step)

                    if let errorMessage {
                        errorBanner(errorMessage)
                            .padding(.top, 20)
                            .transition(.opacity)
                    }
                }
                .animation(.smooth, value: errorMessage)
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemBackground))
        .onAppear { presentLoginNoticeIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { presentLoginNoticeIfNeeded() }
        }
    }

    private func presentLoginNoticeIfNeeded() {
        guard scenePhase == .active, errorMessage == nil else { return }
        errorMessage = session.consumeLoginNotice()
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(.appMark)
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)

            Text("Imora")
                .font(.largeTitle.weight(.bold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
        }
    }

    private var subtitle: String {
        switch step {
        case .server: "Connect to your Immich server"
        case .credentials(let url): url.host() ?? "Sign in"
        }
    }

    // MARK: - step 1, server url

    @ViewBuilder private var serverForm: some View {
        AuthField(
            systemImage: "server.rack",
            placeholder: "demo.immich.app",
            text: $serverInput,
            focus: $focus,
            field: .server
        )
        .keyboardType(.URL)
        .textContentType(.URL)
        .textInputAutocapitalization(.never)
        .submitLabel(.continue)
        .onSubmit { Task { await resolveServer() } }

        Button {
            Task { await resolveServer() }
        } label: {
            busyLabel("Continue")
        }
        .buttonStyle(.borderedProminent)
        .tint(brandTint)
        .disabled(serverInput.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
    }

    // MARK: - step 2, credentials

    private var passwordLoginAvailable: Bool { features?.passwordLogin ?? true }
    private var oauthAvailable: Bool { features?.oauth ?? false }

    @ViewBuilder private var credentialsForm: some View {
        if case .credentials(let apiURL) = step,
           apiURL.scheme?.lowercased() == "http" {
            Label(
                "This local connection is not encrypted. Your password and session token are visible to devices on the network.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if passwordLoginAvailable {
            AuthField(
                systemImage: "envelope",
                placeholder: "Email",
                text: $email,
                focus: $focus,
                field: .email
            )
            .keyboardType(.emailAddress)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .submitLabel(.next)
            .onSubmit { focus = .password }

            AuthField(
                systemImage: "lock",
                isSecure: true,
                placeholder: "Password",
                text: $password,
                focus: $focus,
                field: .password
            )
            .textContentType(.password)
            .submitLabel(.go)
            .onSubmit { Task { await logIn() } }

            Button {
                Task { await logIn() }
            } label: {
                busyLabel("Sign In")
            }
            .buttonStyle(.borderedProminent)
            .tint(brandTint)
            .disabled(email.isEmpty || password.isEmpty || isBusy)
        }

        if oauthAvailable {
            if passwordLoginAvailable {
                separator
                    .padding(.vertical, 2)

                oauthButton(prominent: false)
                    .buttonStyle(.bordered)
                    .tint(brandTint)
                    .disabled(isBusy)
            } else {
                oauthButton(prominent: true)
                    .buttonStyle(.borderedProminent)
                    .tint(brandTint)
                    .disabled(isBusy)
            }
        }

        Button {
            withAnimation(.smooth) {
                step = .server
                errorMessage = nil
                oauthAutoLaunched = false
            }
        } label: {
            Label("Different server", systemImage: "chevron.backward")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(brandTint)
        .padding(.top, 6)
    }

    private var separator: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
            Text("or")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
    }

    private func oauthButton(prominent: Bool) -> some View {
        Button {
            Task { await startOAuth() }
        } label: {
            busyLabel(
                config?.oauthButtonText?.isEmpty == false ? config!.oauthButtonText! : "Continue with OAuth",
                systemImage: "person.badge.key.fill",
                showsProgress: isBusy && !passwordLoginAvailable,
                prominent: prominent
            )
        }
    }

    private func busyLabel(
        _ title: String,
        systemImage: String? = nil,
        showsProgress: Bool? = nil,
        prominent: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress ?? isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(prominent ? .white : brandTint)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - actions

    private func resolveServer() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let apiURL = try await ImmichClient.resolveAPIURL(from: serverInput)
            async let featuresTask = try? ImmichClient.publicFeatures(apiURL: apiURL)
            async let configTask = try? ImmichClient.publicConfig(apiURL: apiURL)
            features = await featuresTask
            config = await configTask
            oauthAutoLaunched = false
            withAnimation(.smooth) { step = .credentials(apiURL) }
            await autoLaunchOAuthIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func autoLaunchOAuthIfNeeded() async {
        guard oauthAvailable,
              features?.oauthAutoLaunch == true,
              !passwordLoginAvailable,
              !oauthAutoLaunched
        else { return }
        oauthAutoLaunched = true
        // let the step transition settle before the sheet slides in.
        try? await Task.sleep(for: .milliseconds(450))
        await startOAuth()
    }

    private func startOAuth() async {
        guard case .credentials(let apiURL) = step, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let response = try await OAuthService.shared.logIn(apiURL: apiURL) else { return }
            await session.logIn(apiURL: apiURL, response: response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func logIn() async {
        guard case .credentials(let apiURL) = step, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await ImmichClient.login(apiURL: apiURL, email: email, password: password)
            ImageLoader.shared.configure(headers: ["Authorization": "Bearer \(response.accessToken)"])
            await session.logIn(apiURL: apiURL, response: response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.red.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - building blocks

private enum AuthFocus {
    case server, email, password
}

private struct AuthField: View {
    let systemImage: String
    var isSecure = false
    let placeholder: String
    @Binding var text: String
    @FocusState.Binding var focus: AuthFocus?
    let field: AuthFocus

    private var shape: RoundedRectangle { .rect(cornerRadius: 14, style: .continuous) }
    private var isFocused: Bool { focus == field }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(isFocused ? brandTint : Color.secondary)
                .frame(width: 22)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled()
                }
            }
            .focused($focus, equals: field)
        }
        .tint(brandTint)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(.secondarySystemBackground), in: shape)
        .overlay(shape.strokeBorder(brandTint.opacity(isFocused ? 1 : 0), lineWidth: 1.5))
        .animation(.smooth(duration: 0.2), value: isFocused)
    }
}
