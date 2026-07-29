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

    private static let serverKey = "imora.serverURL"
    private static let tokenKey = "accessToken"

    var serverURL: URL? {
        UserDefaults.standard.url(forKey: Self.serverKey)
    }

    func restore() async {
        guard state == .restoring else { return }
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
        client = nil
        user = nil
        features = nil
        state = .loggedOut
    }

    func refreshUser() async {
        guard let client else { return }
        if let user = try? await client.currentUser() { self.user = user }
        if let features = try? await client.serverFeatures() { self.features = features }
    }

    private func adopt(client: ImmichClient, user: CurrentUser?) {
        self.client = client
        self.user = user
        ImageLoader.shared.configure(headers: client.authHeaders)
        state = .loggedIn
        Task { await refreshUser() }
    }
}
