import Foundation
import Observation

/// the locked folder's server session: whether this session may read locked
/// assets, the pin lifecycle and the biometric replay. owned by SessionStore
/// so it dies with the login.
@MainActor
@Observable
final class LockedFolderSession {
    enum Phase: Equatable {
        case unknown
        /// the server predates the feature.
        case unsupported
        case needsSetup
        case locked
        case unlocked
    }

    enum BiometricOutcome {
        case unlocked
        case cancelled
        /// no usable stored pin: the enrollment changed, the item is gone or
        /// the pin no longer matches the server. the field takes over.
        case fallback
    }

    private(set) var phase: Phase = .unknown
    private(set) var hasPin = false
    private(set) var hasPassword = false
    private(set) var elevatedUntil: Date?
    private(set) var biometricsEnabled: Bool
    /// the unlocked grid is on screen, so a lock must also close a viewer
    /// presented over it and an inactive scene needs the shield.
    private(set) var isScreenVisible = false

    var isUnlocked: Bool { phase == .unlocked }

    /// offered once after a manual unlock, until enabled or declined.
    var biometricOfferPending: Bool {
        !biometricsEnabled
            && LockedPinStore.biometryType != nil
            && !UserDefaults.standard.bool(forKey: biometricOfferDeclinedKey)
    }

    @ObservationIgnored private let client: ImmichClient
    @ObservationIgnored private let account: String
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    /// bumped by every unlock and lock, so a status fetched before one of
    /// them cannot land late and undo it.
    @ObservationIgnored private var statusRevision = 0

    private var biometricOfferDeclinedKey: String {
        "imora.lockedFolder.biometricOfferDeclined.\(account)"
    }

    init(client: ImmichClient) {
        self.client = client
        let account = client.offlineAccountKey ?? client.apiURL.absoluteString
        self.account = account
        biometricsEnabled = LockedPinStore.exists(account: account)
    }

    // MARK: - status

    func refreshStatus() async {
        // a pop-and-reenter must not read the elevation the lock is still
        // taking down.
        await lockTask?.value
        let revision = statusRevision
        do {
            let status = try await client.authStatus()
            guard revision == statusRevision else { return }
            apply(status)
        } catch ImmichError.http(404, _) {
            phase = .unsupported
        } catch {
            // the first look decides what the screen shows, so it has to say
            // something. a later refresh just keeps what it has.
            guard phase == .unknown else { return }
            phase = .locked
            ErrorToastCenter.shared.show("Couldn’t check the locked folder", error: error)
        }
    }

    private func apply(_ status: AuthStatus) {
        hasPin = status.pinCode
        hasPassword = status.password
        elevatedUntil = status.pinExpiresAt.flatMap { APIDate.parse($0) }
        phase = status.isElevated ? .unlocked : (hasPin ? .locked : .needsSetup)
        scheduleExpiry()
    }

    /// neither official client reads the expiry; the server still enforces
    /// it, so the gate comes back on its own instead of the grid failing.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard phase == .unlocked, let elevatedUntil else { return }
        let delay = elevatedUntil.timeIntervalSinceNow
        // the server just said elevated, so a past date is clock skew.
        guard delay > 0 else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.noteElevationRejected()
        }
    }

    // MARK: - unlocking

    func unlock(pin: String) async throws {
        await lockTask?.value
        try await client.unlockSession(pinCode: pin)
        statusRevision &+= 1
        let revision = statusRevision
        hasPin = true
        phase = .unlocked
        // the unlock answers with nothing; the expiry comes from the status,
        // and a status that cannot be fetched leaves the elevation as is.
        if let status = try? await client.authStatus(), revision == statusRevision {
            apply(status)
        }
    }

    func unlockWithBiometrics() async -> BiometricOutcome {
        guard biometricsEnabled else { return .fallback }
        let pin: String
        do {
            pin = try await LockedPinStore.read(account: account, reason: "Open your locked folder")
        } catch LockedPinStore.Failure.cancelled {
            return .cancelled
        } catch {
            disableBiometrics()
            return .fallback
        }
        do {
            try await unlock(pin: pin)
            return .unlocked
        } catch ImmichError.http(let status, _) where (400..<500).contains(status) {
            // the pin changed on another device, so the stored one is stale.
            disableBiometrics()
            return .fallback
        } catch {
            ErrorToastCenter.shared.show("Couldn’t unlock the locked folder", error: error)
            return .cancelled
        }
    }

    // MARK: - locking

    /// synchronous on purpose: the grid leaves the screen at once and the
    /// server call follows.
    func lock() {
        guard phase == .unlocked else { return }
        enterLockedState()
        lockTask = Task { [client] in
            try? await client.lockSession()
        }
    }

    /// the server already refused the elevation, so only local state moves.
    func noteElevationRejected() {
        guard phase == .unlocked else { return }
        enterLockedState()
    }

    private func enterLockedState() {
        statusRevision &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        elevatedUntil = nil
        if isScreenVisible {
            AssetViewerHostingController.dismissPresentedViewers()
        }
        phase = .locked
    }

    func setScreenVisible(_ visible: Bool) {
        isScreenVisible = visible
    }

    // MARK: - pin lifecycle

    /// creates the pin and opens the folder with it, sparing the second
    /// entry both official clients ask for.
    func setupPin(_ pin: String) async throws {
        try await client.setupPinCode(pin)
        hasPin = true
        try await unlock(pin: pin)
    }

    func changePin(current: String, new: String) async throws {
        try await client.changePinCode(current: current, new: new)
        guard biometricsEnabled else { return }
        do {
            try LockedPinStore.store(new, account: account)
        } catch {
            disableBiometrics()
        }
    }

    func resetPin(password: String) async throws {
        try await client.resetPinCode(password: password)
        disableBiometrics()
        hasPin = false
        phase = .needsSetup
    }

    // MARK: - biometrics

    /// callers verify the pin against the server first; this only stores it.
    func enableBiometrics(pin: String) throws {
        try LockedPinStore.store(pin, account: account)
        biometricsEnabled = true
    }

    func disableBiometrics() {
        LockedPinStore.delete(account: account)
        biometricsEnabled = false
    }

    func declineBiometricOffer() {
        UserDefaults.standard.set(true, forKey: biometricOfferDeclinedKey)
    }

    func shutdown() {
        expiryTask?.cancel()
        lockTask?.cancel()
        disableBiometrics()
        phase = .unknown
    }
}
