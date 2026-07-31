import Foundation
import Observation

/// holds the login state for the whole app.
@Observable
final class SessionStore {
    enum State: Equatable {
        case restoring
        case loggedOut
        case loggedIn
    }

    private(set) var state: State = .restoring
    private(set) var client: ImmichClient?
    private(set) var user: CurrentUser?
    private(set) var features: ServerFeatures?
    private(set) var backup: BackupManager?
    private(set) var realtime: RealtimeHub?
    var preferences: UserPreferences?

    private static let serverKey = "imora.serverURL"
    private static let tokenKey = "accessToken"

    var serverURL: URL? {
        UserDefaults.standard.url(forKey: Self.serverKey)
    }

    func restore() async {
        guard state == .restoring else { return }
        #if DEBUG
        // ui test runs pin the server via env; a persisted session from a
        // different server must not win over it.
        if let envServer = ProcessInfo.processInfo.environment["IMORA_SERVER"],
           let envHost = URL(string: envServer)?.host(),
           let stored = serverURL, stored.host() != envHost {
            UserDefaults.standard.removeObject(forKey: Self.serverKey)
            KeychainStore.delete(Self.tokenKey)
            state = .loggedOut
            return
        }
        #endif
        guard let apiURL = serverURL, let token = KeychainStore.get(Self.tokenKey) else {
            state = .loggedOut
            return
        }
        let client = ImmichClient(apiURL: apiURL, accessToken: token)
        do {
            let user = try await client.currentUser()
            adopt(client: client, user: user)
        } catch ImmichError.http(401, _) {
            KeychainStore.delete(Self.tokenKey)
            state = .loggedOut
        } catch {
            // offline or transient failure: keep the session, features stay nil until refreshed.
            adopt(client: client, user: nil)
        }
    }

    func logIn(apiURL: URL, response: LoginResponse) async {
        UserDefaults.standard.set(apiURL, forKey: Self.serverKey)
        KeychainStore.set(response.accessToken, for: Self.tokenKey)
        let client = ImmichClient(apiURL: apiURL, accessToken: response.accessToken)
        let user = try? await client.currentUser()
        adopt(client: client, user: user)
    }

    func logOut() async {
        if let client {
            await client.logout()
        }
        KeychainStore.delete(Self.tokenKey)
        realtime?.shutdown()
        realtime = nil
        backup?.shutdown()
        backup = nil
        client = nil
        user = nil
        features = nil
        state = .loggedOut
    }

    func refreshUser() async {
        guard let client else { return }
        async let userTask = try? client.currentUser()
        async let featuresTask = try? client.serverFeatures()
        async let preferencesTask = try? client.preferences()
        if let user = await userTask {
            self.user = user
            backup?.userId = user.id
            await backup?.primeLocalState()
        }
        if let features = await featuresTask { self.features = features }
        if let preferences = await preferencesTask { self.preferences = preferences }
    }

    private func adopt(client: ImmichClient, user: CurrentUser?) {
        self.client = client
        self.user = user
        ImageLoader.shared.configure(headers: client.authHeaders)
        let backup = BackupManager(client: client)
        backup.userId = user?.id
        self.backup = backup
        let hub = RealtimeHub(client: client)
        backup.onLocalChange = { [weak hub] in hub?.notifyLocalChange() }
        realtime = hub
        state = .loggedIn
        Task { await refreshUser() }
        backup.startIfIdle()
        hub.setActive(true)
    }
}
