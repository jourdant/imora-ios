import Foundation
import Observation

/// holds the login state for the whole app.
@Observable
final class SessionStore {
    enum State: Equatable {
        case loggedOut
        case loggedIn
    }

    private(set) var state: State = .loggedOut
    private(set) var client: ImmichClient?
    private(set) var user: CurrentUser?
    private(set) var features: ServerFeatures?
    private(set) var backup: BackupManager?
    private(set) var realtime: RealtimeHub?
    private(set) var notifications: NotificationInbox?
    var preferences: UserPreferences?

    private static let serverKey = "imora.serverURL"
    private static let tokenKey = "accessToken"

    var serverURL: URL? {
        UserDefaults.standard.url(forKey: Self.serverKey)
    }

    /// a stored session is adopted before the first frame, so there is no
    /// launch spinner: the tabs come up on cached account details and the
    /// server confirms them in the background. an expired token only shows
    /// once the refresh comes back 401.
    init() {
        #if DEBUG
        // ui test runs pin the server via env; a persisted session from a
        // different server must not win over it.
        if let envServer = ProcessInfo.processInfo.environment["IMORA_SERVER"],
           let envHost = URL(string: envServer)?.host(),
           let stored = serverURL, stored.host() != envHost {
            UserDefaults.standard.removeObject(forKey: Self.serverKey)
            KeychainStore.delete(Self.tokenKey)
            SessionCache.clear()
            state = .loggedOut
            return
        }
        #endif
        guard let apiURL = serverURL, let token = KeychainStore.get(Self.tokenKey) else {
            state = .loggedOut
            return
        }
        // re-setting moves tokens from before keychain sharing into the app
        // group access group, and the mirror keeps the extension current.
        KeychainStore.set(token, for: Self.tokenKey)
        mirrorForShareExtension(apiURL: apiURL)
        let cached = apiURL.host().flatMap { SessionCache.load(host: $0) }
        features = cached?.features
        preferences = cached?.preferences
        adopt(client: ImmichClient(apiURL: apiURL, accessToken: token), user: cached?.user)
    }

    func logIn(apiURL: URL, response: LoginResponse) async {
        UserDefaults.standard.set(apiURL, forKey: Self.serverKey)
        KeychainStore.set(response.accessToken, for: Self.tokenKey)
        mirrorForShareExtension(apiURL: apiURL)
        SessionCache.noteUserId(response.userId)
        let client = ImmichClient(apiURL: apiURL, accessToken: response.accessToken)
        let user = try? await client.currentUser()
        adopt(client: client, user: user)
    }

    func logOut() async {
        if let client {
            await client.logout()
        }
        KeychainStore.delete(Self.tokenKey)
        SessionCache.clear()
        realtime?.shutdown()
        realtime = nil
        backup?.shutdown()
        backup = nil
        notifications?.clear()
        notifications = nil
        ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.serverURLKey)
        ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.deviceIdKey)
        ContinuedProcessing.backup.workload = nil
        client = nil
        user = nil
        features = nil
        state = .loggedOut
    }

    func refreshUser() async {
        guard let client else { return }
        // the user call doubles as the token check the launch no longer waits
        // for: a rejected token ends the session here instead of leaving the
        // app pointed at a server that will refuse everything.
        do {
            let user = try await client.currentUser()
            self.user = user
            SessionCache.noteUserId(user.id)
            backup?.userId = user.id
            await backup?.primeLocalState()
        } catch ImmichError.http(401, _) {
            await logOut()
            return
        } catch {
            // offline or transient: keep the cached account details.
        }
        async let featuresTask = try? client.serverFeatures()
        async let preferencesTask = try? client.preferences()
        if let features = await featuresTask { self.features = features }
        if let preferences = await preferencesTask { self.preferences = preferences }
        cacheSnapshot()
    }

    /// called after the user grants library access mid-session, so the change
    /// observer, badges and auto backup pick it up without a relaunch.
    func adoptPhotoAccess() async {
        await backup?.primeLocalState()
        backup?.startIfIdle()
    }

    /// the share extension uploads with this session, and the app group is
    /// all it can read.
    private func mirrorForShareExtension(apiURL: URL) {
        let defaults = ShareTransfer.defaults
        defaults?.set(apiURL.absoluteString, forKey: ShareTransfer.serverURLKey)
        defaults?.set(DeviceID.current, forKey: ShareTransfer.deviceIdKey)
    }

    private func cacheSnapshot() {
        guard let host = client?.apiURL.host() else { return }
        SessionCache.save(
            SessionCache.Snapshot(host: host, user: user, features: features, preferences: preferences)
        )
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
        backup.onRunFinished = { phase in
            switch phase {
            case .done(let summary): LocalNotifications.shared.deliverBackupReport(summary)
            case .error(let message): LocalNotifications.shared.deliverBackupFailure(message)
            default: break
            }
        }
        ContinuedProcessing.backup.workload = backup
        hub.onRemoteEdit = { [weak backup] ids in backup?.noteRemoteEdits(ids) }
        realtime = hub
        let inbox = NotificationInbox(client: client)
        hub.addListener(inbox)
        notifications = inbox
        state = .loggedIn
        Task { await refreshUser() }
        Task { await inbox.load() }
        backup.startIfIdle()
        hub.setActive(true)
    }
}
