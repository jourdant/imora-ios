import Foundation
import Observation
import UIKit

nonisolated struct ProfileImageMutationToken {
    fileprivate let id: UUID
    fileprivate let previousData: Data?
    fileprivate let previousCacheKey: String?
}

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
    private(set) var notifications: NotificationInbox?
    private(set) var preferences: UserPreferences?
    private(set) var loginNotice: String?
    /// Keeps a newly selected avatar visible while the server accepts and
    /// re-caches the same bytes. A rejected upload restores the prior value.
    var optimisticProfileImageData: Data? {
        didSet {
            optimisticProfileImage = optimisticProfileImageData.flatMap { UIImage(data: $0) }
        }
    }
    /// decoded once when the bytes land. avatars used to rebuild a uiimage
    /// from the raw picked photo on every body pass while an upload ran.
    private(set) var optimisticProfileImage: UIImage?
    var profileImageCacheKey: String?
    private(set) var isProfileImageMutationInFlight = false
    @ObservationIgnored private var profileImageMutationID: UUID?
    @ObservationIgnored private var preferenceProjectionRevisions: [String: Int] = [:]
    @ObservationIgnored private var pendingPreferenceMutationCounts: [String: Int] = [:]
    @ObservationIgnored private var refreshUserRevision = 0

    private static let serverKey = "imora.serverURL"
    private static let tokenKey = "accessToken"
    private static let loginNoticeDefaultsKey = "imora.loginNotice"
    private static let profileImageCacheKeyDefaultsKey = "imora.profileImageCacheKey"

    var serverURL: URL? {
        UserDefaults.standard.url(forKey: Self.serverKey)
    }

    /// a stored session is adopted before the first frame, so there is no
    /// launch spinner: the tabs come up on cached account details and the
    /// server confirms them in the background. an expired token only shows
    /// once the refresh comes back 401.
    init() {
        loginNotice = UserDefaults.standard.string(forKey: Self.loginNoticeDefaultsKey)
        profileImageCacheKey = UserDefaults.standard.string(
            forKey: Self.profileImageCacheKeyDefaultsKey
        )
        restoreSessionIfAvailable()
    }

    /// retries a keychain read that was blocked while protected data was unavailable.
    func restoreSessionIfAvailable() {
        guard state == .restoring else { return }
        guard let apiURL = serverURL else {
            state = .loggedOut
            return
        }
        let token: String
        switch KeychainStore.get(Self.tokenKey) {
        case .value(let storedToken):
            token = storedToken
        case .missing:
            state = .loggedOut
            return
        case .unavailable:
            return
        }
        guard ImmichClient.supportsTransport(to: apiURL) else {
            KeychainStore.delete(Self.tokenKey)
            SessionCache.clear()
            ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.serverURLKey)
            ShareTransfer.defaults?.removeObject(forKey: ShareTransfer.deviceIdKey)
            let notice = "Your saved server uses HTTP outside your local network. Sign in again with HTTPS or a local-network address."
            loginNotice = notice
            UserDefaults.standard.set(notice, forKey: Self.loginNoticeDefaultsKey)
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
        loginNotice = nil
        UserDefaults.standard.removeObject(forKey: Self.loginNoticeDefaultsKey)
        UserDefaults.standard.set(apiURL, forKey: Self.serverKey)
        KeychainStore.set(response.accessToken, for: Self.tokenKey)
        mirrorForShareExtension(apiURL: apiURL)
        SessionCache.noteUserId(response.userId)
        let client = ImmichClient(apiURL: apiURL, accessToken: response.accessToken)
        let user = try? await client.currentUser()
        adopt(client: client, user: user)
    }

    func consumeLoginNotice() -> String? {
        defer { loginNotice = nil }
        UserDefaults.standard.removeObject(forKey: Self.loginNoticeDefaultsKey)
        return loginNotice
    }

    func logOut(reportRemoteFailure: Bool = true) async {
        let signingOutClient = client
        refreshUserRevision &+= 1
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
        preferences = nil
        preferenceProjectionRevisions = [:]
        pendingPreferenceMutationCounts = [:]
        optimisticProfileImageData = nil
        profileImageCacheKey = nil
        isProfileImageMutationInFlight = false
        profileImageMutationID = nil
        state = .loggedOut

        guard let signingOutClient else { return }
        do {
            try await signingOutClient.logout()
        } catch where reportRemoteFailure {
            ErrorToastCenter.shared.show(
                "Signed out on this device, but couldn’t close the server session",
                error: error
            )
        } catch {
            // An already rejected session is locally complete; no rollback is
            // safe or useful for a best-effort remote logout.
        }
    }

    func refreshUser() async {
        guard let client else { return }
        refreshUserRevision &+= 1
        let revision = refreshUserRevision
        // the user call doubles as the token check the launch no longer waits
        // for: a rejected token ends the session here instead of leaving the
        // app pointed at a server that will refuse everything.
        do {
            let user = try await client.currentUser()
            guard revision == refreshUserRevision, self.client === client else { return }
            self.user = user
            SessionCache.noteUserId(user.id)
            backup?.userId = user.id
            await backup?.primeLocalState()
        } catch ImmichError.http(401, _) {
            guard revision == refreshUserRevision, self.client === client else { return }
            await logOut(reportRemoteFailure: false)
            return
        } catch {
            // offline or transient: keep the cached account details.
        }
        guard revision == refreshUserRevision, self.client === client else { return }
        let preferenceRevisionsAtRequest = preferenceProjectionRevisions
        let pendingPreferenceFieldsAtRequest = Set(
            pendingPreferenceMutationCounts.lazy.filter { $0.value > 0 }.map(\.key)
        )
        async let featuresTask = try? client.serverFeatures()
        async let preferencesTask = try? client.preferences()
        if let features = await featuresTask,
           revision == refreshUserRevision,
           self.client === client {
            self.features = features
        }
        if let fetched = await preferencesTask {
            guard revision == refreshUserRevision, self.client === client else { return }
            preferences = mergedPreferences(
                fetched,
                preservingChangesSince: preferenceRevisionsAtRequest,
                pendingAtRequest: pendingPreferenceFieldsAtRequest
            )
        }
        cacheSnapshot()
    }

    /// called after the user grants library access mid-session, so the change
    /// observer, badges and auto backup pick it up without a relaunch.
    func adoptPhotoAccess() async {
        await backup?.primeLocalState()
        backup?.startIfIdle()
    }

    /// portrait url for a person, carrying a cache-buster: the socket's key
    /// when this session watched the server re-render them, otherwise the
    /// person's own updatedAt, which is what catches a change made on another
    /// device while imora was closed. every avatar goes through here so a new
    /// featured photo shows up everywhere at once.
    func personThumbnailURL(_ person: Person) -> URL? {
        client?.personThumbnailURL(
            personID: person.id,
            cacheKey: realtime?.personThumbnailKeys[person.id] ?? person.updatedAt
        )
    }

    func beginProfileImageMutation(data: Data) -> ProfileImageMutationToken? {
        guard !isProfileImageMutationInFlight else { return nil }
        let token = ProfileImageMutationToken(
            id: UUID(),
            previousData: optimisticProfileImageData,
            previousCacheKey: profileImageCacheKey
        )
        profileImageMutationID = token.id
        isProfileImageMutationInFlight = true
        optimisticProfileImageData = data
        return token
    }

    func projectPreferences(_ projection: UserPreferences, field: String) {
        preferenceProjectionRevisions[field, default: 0] &+= 1
        preferences = projection
    }

    func setPreferenceMutation(_ field: String, active: Bool) {
        if active {
            pendingPreferenceMutationCounts[field, default: 0] += 1
        } else {
            let remaining = max(0, pendingPreferenceMutationCounts[field, default: 0] - 1)
            if remaining == 0 {
                pendingPreferenceMutationCounts[field] = nil
            } else {
                pendingPreferenceMutationCounts[field] = remaining
            }
        }
    }

    /// Installs a cache-busting URL only for the still-current upload.
    func acceptProfileImageMutation(
        _ token: ProfileImageMutationToken,
        cacheKey: String
    ) -> Bool {
        guard profileImageMutationID == token.id else { return false }
        profileImageCacheKey = cacheKey
        UserDefaults.standard.set(cacheKey, forKey: Self.profileImageCacheKeyDefaultsKey)
        return true
    }

    func finishProfileImageMutation(
        _ token: ProfileImageMutationToken,
        canonicalImageIsCached: Bool
    ) {
        guard profileImageMutationID == token.id else { return }
        if canonicalImageIsCached { optimisticProfileImageData = nil }
        profileImageMutationID = nil
        isProfileImageMutationInFlight = false
    }

    func rollbackProfileImageMutation(_ token: ProfileImageMutationToken) {
        guard profileImageMutationID == token.id else { return }
        optimisticProfileImageData = token.previousData
        profileImageCacheKey = token.previousCacheKey
        profileImageMutationID = nil
        isProfileImageMutationInFlight = false
    }

    private func mergedPreferences(
        _ fetched: UserPreferences,
        preservingChangesSince snapshot: [String: Int],
        pendingAtRequest: Set<String>
    ) -> UserPreferences {
        guard let current = preferences else { return fetched }
        let changed: (String) -> Bool = { key in
            self.preferenceProjectionRevisions[key, default: 0] != snapshot[key, default: 0]
        }
        var fields = pendingAtRequest
        fields.formUnion(["memories", "people", "email"].filter(changed))
        return fetched.preservingProjectedFields(
            from: current,
            fields: fields
        )
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
        if profileImageCacheKey == nil {
            profileImageCacheKey = UserDefaults.standard.string(
                forKey: Self.profileImageCacheKeyDefaultsKey
            )
        }
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
        // the index is on disk and the account is cached, so the pairing maps
        // that let tiles render from the device are ready before the server
        // has answered; refreshUser primes again once the account is confirmed.
        Task { await backup.primeLocalState() }
        Task { await refreshUser() }
        Task { await inbox.load() }
        backup.startIfIdle()
        hub.setActive(true)
    }
}

nonisolated extension UserPreferences {
    func preservingProjectedFields(
        from projected: UserPreferences,
        fields: Set<String>
    ) -> UserPreferences {
        UserPreferences(
            memories: fields.contains("memories") ? projected.memories : memories,
            people: fields.contains("people") ? projected.people : people,
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: fields.contains("email")
                ? projected.emailNotifications
                : emailNotifications
        )
    }
}
