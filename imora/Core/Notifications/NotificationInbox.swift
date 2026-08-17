import Foundation
import Observation

/// carries notification taps into swiftui navigation. the tab shell consumes
/// the pending values and clears them.
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    var pendingAlbumID: String?
    var showsInbox = false

    private init() {}

    func openAlbum(_ id: String) {
        showsInbox = false
        pendingAlbumID = id
    }

    func openInbox() {
        showsInbox = true
    }
}

nonisolated protocol NotificationServicing: Sendable {
    func notifications(unreadOnly: Bool) async throws -> [ServerNotification]
    func markNotificationRead(id: String, at date: Date) async throws
    func markNotificationsRead(ids: [String], at date: Date) async throws
    func deleteNotifications(ids: [String]) async throws
}

extension ImmichClient: NotificationServicing {}

@MainActor
protocol NotificationBadgeManaging: AnyObject {
    func setBadge(_ count: Int)
    func clearAll()
}

extension LocalNotifications: NotificationBadgeManaging {}

/// the server-side inbox, GET /notifications plus the on_notification socket
/// event. entries stay in this list: without a push transport a native banner
/// could only ever appear over the open app, duplicating what the inbox
/// already shows. the app icon badge still mirrors the unread count.
@Observable
final class NotificationInbox: RealtimeListener {
    private(set) var items: [ServerNotification] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false
    /// distinguishes "not fetched yet" from "the server says none", so the
    /// inbox does not flash its empty state before the first load resolves.
    private(set) var hasLoaded = false

    private enum Projection {
        case present(ServerNotification)
        case removed

        var notification: ServerNotification? {
            guard case .present(let notification) = self else { return nil }
            return notification
        }
    }

    private struct ItemOperationState {
        var confirmed: ServerNotification?
        var hasConfirmed = false
        var revision = 0
        var externalRevision = 0
        var tail: Task<Void, Never>?
        var tailID: UUID?
    }

    private struct LoadContext {
        let lifecycleRevision: Int
        let itemRevisions: [String: Int]
        let pendingIDs: Set<String>
    }

    private let client: any NotificationServicing
    private let local: any NotificationBadgeManaging
    private let feedback: ErrorToastCenter
    private var operationStates: [String: ItemOperationState] = [:]
    private var lifecycleRevision = 0

    init(
        client: any NotificationServicing,
        local: (any NotificationBadgeManaging)? = nil,
        feedback: ErrorToastCenter? = nil
    ) {
        self.client = client
        self.local = local ?? LocalNotifications.shared
        self.feedback = feedback ?? ErrorToastCenter.shared
    }

    var unread: [ServerNotification] { items.filter(\.isUnread) }

    // MARK: - loading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let context = loadContext()
        guard let fetched = try? await client.notifications(unreadOnly: false) else { return }
        guard lifecycleRevision == context.lifecycleRevision else { return }
        hasLoaded = true
        mergeServerSnapshot(fetched, preservingChangesSince: context)
        sync()
    }

    // MARK: - mutations

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isUnread else { return }
        let now = Date()
        var notification = items[index]
        notification.readAt = now
        mutate(
            projections: [id: .present(notification)],
            errorMessage: "Couldn’t mark the notification as read"
        ) { [client] in
            try await client.markNotificationRead(id: id, at: now)
        }
    }

    func markAllRead() {
        let ids = unread.map(\.id)
        guard !ids.isEmpty else { return }
        let now = Date()
        let projections = Dictionary(uniqueKeysWithValues: unread.map { item in
            var notification = item
            notification.readAt = now
            return (item.id, Projection.present(notification))
        })
        mutate(
            projections: projections,
            errorMessage: "Couldn’t mark notifications as read"
        ) { [client] in
            try await client.markNotificationsRead(ids: ids, at: now)
        }
    }

    func delete(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        mutate(
            projections: [id: .removed],
            errorMessage: "Couldn’t delete the notification"
        ) { [client] in
            try await client.deleteNotifications(ids: [id])
        }
    }

    func deleteAll() {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        mutate(
            projections: Dictionary(uniqueKeysWithValues: ids.map { ($0, Projection.removed) }),
            errorMessage: "Couldn’t clear notifications"
        ) { [client] in
            try await client.deleteNotifications(ids: ids)
        }
    }

    /// called on logout: the badge and any lingering backup banner belong to
    /// an account that is no longer signed in.
    func clear() {
        lifecycleRevision &+= 1
        items = []
        unreadCount = 0
        operationStates.removeAll()
        local.clearAll()
    }

    // MARK: - realtime

    func realtimeNotification(_ notification: ServerNotification) {
        supersedeOperations(for: notification.id, with: notification)
        upsert(notification)
        items.sort(by: Self.newestFirst)
        sync()
    }

    // MARK: - internals

    private func sync() {
        unreadCount = items.filter(\.isUnread).count
        local.setBadge(unreadCount)
    }

    private func mutate(
        projections: [String: Projection],
        errorMessage: String,
        request: @escaping @MainActor () async throws -> Void
    ) {
        let operationID = UUID()
        let prepared = prepareMutation(for: projections.keys)
        apply(projections, revisions: prepared.revisions)

        let operation = Task { [self] in
            await OptimisticAction.perform(
                errorMessage: errorMessage,
                apply: { apply(projections, revisions: prepared.revisions) },
                rollback: {
                    rollback(revisions: prepared.revisions, externalRevisions: prepared.externalRevisions)
                },
                request: {
                    for predecessor in prepared.predecessors { await predecessor.value }
                    return try await request()
                },
                commit: { _ in
                    confirm(projections, externalRevisions: prepared.externalRevisions)
                },
                reportFailure: { [feedback] message, error in
                    feedback.show(message, error: error)
                }
            )
            finish(operationID, ids: Array(projections.keys))
        }
        attach(operation, id: operationID, to: projections.keys)
    }

    private func prepareMutation(
        for ids: Dictionary<String, Projection>.Keys
    ) -> (revisions: [String: Int], externalRevisions: [String: Int], predecessors: [Task<Void, Never>]) {
        var revisions: [String: Int] = [:]
        var externalRevisions: [String: Int] = [:]
        var predecessors: [Task<Void, Never>] = []
        for id in ids {
            var state = operationState(for: id)
            state.revision += 1
            revisions[id] = state.revision
            externalRevisions[id] = state.externalRevision
            if let predecessor = state.tail { predecessors.append(predecessor) }
            operationStates[id] = state
        }
        return (revisions, externalRevisions, predecessors)
    }

    private func operationState(for id: String) -> ItemOperationState {
        var state = operationStates[id] ?? ItemOperationState()
        guard !state.hasConfirmed else { return state }
        state.confirmed = items.first { $0.id == id }
        state.hasConfirmed = true
        return state
    }

    private func apply(_ projections: [String: Projection], revisions: [String: Int]) {
        for (id, projection) in projections where operationStates[id]?.revision == revisions[id] {
            project(projection, id: id)
        }
        items.sort(by: Self.newestFirst)
        sync()
    }

    private func rollback(
        revisions: [String: Int],
        externalRevisions: [String: Int]
    ) {
        for (id, revision) in revisions {
            guard let state = operationStates[id],
                  state.revision == revision,
                  state.externalRevision == externalRevisions[id]
            else { continue }
            let projection = state.confirmed.map(Projection.present) ?? .removed
            project(projection, id: id)
        }
        items.sort(by: Self.newestFirst)
        sync()
    }

    private func confirm(
        _ projections: [String: Projection],
        externalRevisions: [String: Int]
    ) {
        for (id, projection) in projections {
            guard var state = operationStates[id],
                  state.externalRevision == externalRevisions[id]
            else { continue }
            state.confirmed = projection.notification
            state.hasConfirmed = true
            operationStates[id] = state
        }
    }

    private func project(_ projection: Projection, id: String) {
        switch projection {
        case .present(let notification): upsert(notification)
        case .removed: items.removeAll { $0.id == id }
        }
    }

    private func upsert(_ notification: ServerNotification) {
        guard let index = items.firstIndex(where: { $0.id == notification.id }) else {
            items.append(notification)
            return
        }
        items[index] = notification
    }

    private func attach(
        _ task: Task<Void, Never>,
        id operationID: UUID,
        to ids: Dictionary<String, Projection>.Keys
    ) {
        for id in ids {
            guard var state = operationStates[id] else { continue }
            state.tail = task
            state.tailID = operationID
            operationStates[id] = state
        }
    }

    private func finish(_ operationID: UUID, ids: [String]) {
        for id in ids {
            guard var state = operationStates[id], state.tailID == operationID else { continue }
            state.tail = nil
            state.tailID = nil
            operationStates[id] = state
        }
    }

    private func supersedeOperations(for id: String, with notification: ServerNotification?) {
        var state = operationState(for: id)
        state.revision += 1
        state.externalRevision += 1
        state.confirmed = notification
        state.hasConfirmed = true
        operationStates[id] = state
    }

    private func loadContext() -> LoadContext {
        let ids = Set(items.map(\.id)).union(operationStates.keys)
        return LoadContext(
            lifecycleRevision: lifecycleRevision,
            itemRevisions: Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, operationStates[id]?.revision ?? 0)
            }),
            pendingIDs: Set(ids.filter { operationStates[$0]?.tail != nil })
        )
    }

    /// A response describes the server state when its request began, not when
    /// it arrives. Keep the local projection for every item that had a queued
    /// mutation at that point or changed while the request was in flight.
    private func mergeServerSnapshot(
        _ fetched: [ServerNotification],
        preservingChangesSince context: LoadContext
    ) {
        let fetchedByID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let currentByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ids = Set(currentByID.keys).union(fetchedByID.keys)
        var merged: [ServerNotification] = []

        for id in ids {
            let currentState = operationStates[id]
            let revisionAtStart = context.itemRevisions[id] ?? 0
            let changedDuringLoad = (currentState?.revision ?? 0) != revisionAtStart
            let preservesLocalProjection = context.pendingIDs.contains(id)
                || currentState?.tail != nil
                || changedDuringLoad

            if preservesLocalProjection {
                if let current = currentByID[id] { merged.append(current) }
            } else {
                let serverNotification = fetchedByID[id]
                supersedeOperations(for: id, with: serverNotification)
                if let serverNotification { merged.append(serverNotification) }
            }
        }

        items = merged.sorted(by: Self.newestFirst)
    }

    private static func newestFirst(_ lhs: ServerNotification, _ rhs: ServerNotification) -> Bool {
        lhs.createdAt > rhs.createdAt
    }
}
