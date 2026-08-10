import Observation
import Foundation

/// Serializes one independently editable value per asset. Every intent is
/// projected synchronously; only the newest intent may repaint or roll back a
/// given asset, while the confirmed value advances after each accepted write.
@Observable
@MainActor
final class AssetOptimisticField<Value: Equatable> {
    nonisolated struct LoadSnapshot: Equatable {
        fileprivate let mutationRevision: UInt64
        fileprivate let loadGeneration: UInt64
        fileprivate let startedWhilePending: Bool
    }

    private struct Channel {
        var confirmed: Value?
        var hasConfirmed = false
        var mutationRevision: UInt64 = 0
        var loadGeneration: UInt64 = 0
        var tail: Task<Void, Never>?
        var tailID: UUID?
    }

    @ObservationIgnored private var channels: [String: Channel] = [:]
    private(set) var pendingAssetIDs: Set<String> = []

    func isPending(for assetID: String) -> Bool {
        pendingAssetIDs.contains(assetID)
    }

    /// Begins a server read. A response is adoptable only when it is still the
    /// newest read and no mutation overlapped it in either direction.
    func loadSnapshot(for assetID: String) -> LoadSnapshot {
        var channel = channels[assetID] ?? Channel()
        channel.loadGeneration &+= 1
        channels[assetID] = channel
        return LoadSnapshot(
            mutationRevision: channel.mutationRevision,
            loadGeneration: channel.loadGeneration,
            startedWhilePending: channel.tail != nil
        )
    }

    func canAdoptServerValue(for assetID: String, since snapshot: LoadSnapshot) -> Bool {
        let channel = channels[assetID] ?? Channel()
        return !snapshot.startedWhilePending
            && channel.tail == nil
            && channel.mutationRevision == snapshot.mutationRevision
            && channel.loadGeneration == snapshot.loadGeneration
    }

    /// Seeds the rollback baseline after an accepted, non-stale server read.
    func adoptServerValue(_ value: Value, for assetID: String) {
        var channel = channels[assetID] ?? Channel()
        guard channel.tail == nil else { return }
        channel.confirmed = value
        channel.hasConfirmed = true
        channels[assetID] = channel
    }

    func submit(
        assetID: String,
        current: Value,
        desired: Value,
        errorMessage: String,
        apply: @escaping @MainActor (String, Value) -> Void,
        request: @escaping @MainActor (Value) async throws -> Value,
        latestCommit: @escaping @MainActor (String, Value) -> Void = { _, _ in },
        reportFailure: @escaping @MainActor (String, Error) -> Void = { message, error in
            ErrorToastCenter.shared.show(message, error: error)
        }
    ) {
        var channel = channels[assetID] ?? Channel()
        if channel.tail == nil {
            channel.confirmed = current
            channel.hasConfirmed = true
            pendingAssetIDs.insert(assetID)
        }
        channel.mutationRevision &+= 1
        let revision = channel.mutationRevision
        let predecessor = channel.tail
        let tailID = UUID()
        channel.tailID = tailID
        channels[assetID] = channel

        apply(assetID, desired)

        let task = Task { [self] in
            await OptimisticAction.perform(
                errorMessage: errorMessage,
                apply: {
                    guard channels[assetID]?.mutationRevision == revision else { return }
                    apply(assetID, desired)
                },
                rollback: {
                    guard let channel = channels[assetID],
                          channel.mutationRevision == revision,
                          channel.hasConfirmed,
                          let confirmed = channel.confirmed
                    else { return }
                    apply(assetID, confirmed)
                },
                request: {
                    await predecessor?.value
                    return try await request(desired)
                },
                commit: { authoritative in
                    guard var channel = channels[assetID] else { return }
                    channel.confirmed = authoritative
                    channel.hasConfirmed = true
                    channels[assetID] = channel
                    guard channel.mutationRevision == revision else { return }
                    apply(assetID, authoritative)
                    latestCommit(assetID, authoritative)
                },
                reportFailure: reportFailure
            )

            guard var channel = channels[assetID], channel.tailID == tailID else { return }
            channel.tail = nil
            channel.tailID = nil
            channels[assetID] = channel
            pendingAssetIDs.remove(assetID)
        }

        channel = channels[assetID] ?? channel
        channel.tail = task
        channels[assetID] = channel
    }
}
