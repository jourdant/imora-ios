import SwiftUI

struct LoginFlowView: View {
    @Environment(SessionStore.self) private var session

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
    @Namespace private var glass

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 92)
                        .glassEffect(.regular.tint(.indigo.opacity(0.4)), in: .rect(cornerRadius: 24))

                    Text("Imora")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                .padding(.bottom, 36)

                GlassEffectContainer(spacing: 20) {
                    VStack(spacing: 16) {
                        switch step {
                        case .server:
                            serverForm
                        case .credentials:
                            credentialsForm
                        }
                    }
                }
                .padding(.horizontal, 28)
                .animation(.smooth(duration: 0.35), value: step)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.tint(.red.opacity(0.55)), in: .capsule)
                        .padding(.top, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()
                Spacer()
            }
            .animation(.smooth, value: errorMessage)
        }
        .task { await debugAutoLogin() }
    }

    /// lets ui tests and simulator runs log in from environment variables.
    /// with only a server set, it resolves and stops on the credentials step.
    private func debugAutoLogin() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let server = env["IMORA_SERVER"] else { return }
        serverInput = server
        await resolveServer()
        if let mail = env["IMORA_EMAIL"], let pass = env["IMORA_PASSWORD"] {
            email = mail
            password = pass
            await logIn()
        }
        #endif
    }

    private var subtitle: String {
        switch step {
        case .server: "Connect to your Immich server"
        case .credentials(let url): url.host() ?? "Sign in"
        }
    }

    // MARK: - step 1, server url

    @ViewBuilder private var serverForm: some View {
        GlassField(systemImage: "server.rack", isSecure: false, placeholder: "server.example.com", text: $serverInput)
            .keyboardType(.URL)
            .textContentType(.URL)
            .glassEffectID("field-1", in: glass)
            .onSubmit { Task { await resolveServer() } }

        Button {
            Task { await resolveServer() }
        } label: {
            busyLabel("Continue")
        }
        .buttonStyle(.glassProminent)
        .tint(.indigo)
        .disabled(serverInput.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
        .glassEffectID("cta", in: glass)
    }

    // MARK: - step 2, credentials

    private var passwordLoginAvailable: Bool { features?.passwordLogin ?? true }
    private var oauthAvailable: Bool { features?.oauth ?? false }

    @ViewBuilder private var credentialsForm: some View {
        if passwordLoginAvailable {
            GlassField(systemImage: "envelope", isSecure: false, placeholder: "Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .glassEffectID("field-1", in: glass)

            GlassField(systemImage: "lock", isSecure: true, placeholder: "Password", text: $password)
                .textContentType(.password)
                .onSubmit { Task { await logIn() } }
                .glassEffectID("field-2", in: glass)

            Button {
                Task { await logIn() }
            } label: {
                busyLabel("Sign In")
            }
            .buttonStyle(.glassProminent)
            .tint(.indigo)
            .disabled(email.isEmpty || password.isEmpty || isBusy)
            .glassEffectID("cta", in: glass)
        }

        if oauthAvailable {
            if passwordLoginAvailable {
                Text("or")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }

            if passwordLoginAvailable {
                oauthButtonLabel
                    .buttonStyle(.glass)
                    .disabled(isBusy)
                    .glassEffectID("oauth", in: glass)
            } else {
                oauthButtonLabel
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    .disabled(isBusy)
                    .glassEffectID("cta", in: glass)
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
                .foregroundStyle(.white.opacity(0.85))
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var oauthButtonLabel: some View {
        Button {
            Task { await startOAuth() }
        } label: {
            HStack(spacing: 8) {
                if isBusy && !passwordLoginAvailable {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "person.badge.key.fill")
                }
                Text(config?.oauthButtonText?.isEmpty == false ? config!.oauthButtonText! : "Continue with OAuth")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private func busyLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().tint(.white)
            }
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
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
}

// MARK: - building blocks

private struct GlassField: View {
    let systemImage: String
    let isSecure: Bool
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .autocorrectionDisabled()
                }
            }
            .foregroundStyle(.white)
            .tint(.white)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .capsule)
    }
}

/// slowly drifting mesh gradient behind the login card.
struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], animate ? [0.65, 0.45] : [0.35, 0.55], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                .black, .indigo.opacity(0.85), .black,
                .purple.opacity(0.7), .indigo, .blue.opacity(0.75),
                .black, .purple.opacity(0.8), .black,
            ]
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}
