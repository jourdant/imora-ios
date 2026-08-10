import Foundation

/// Projects every intent immediately while keeping writes to one server value
/// in issue order. The confirmed value advances after each successful write,
/// so a rejected later intent rolls back to what the server last accepted.
@MainActor
final class SerialOptimisticValue<Value> {
    private struct State {
        var confirmed: Value?
        var revision = 0
        var tail: Task<Void, Never>?
    }

    private var state = State()

    func submit(
        current: Value,
        desired: Value,
        errorMessage: String,
        apply: @escaping @MainActor (Value) -> Void,
        request: @escaping @MainActor (Value) async throws -> Value,
        activityChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        reportFailure: @escaping @MainActor (String, Error) -> Void = { message, error in
            ErrorToastCenter.shared.show(message, error: error)
        }
    ) {
        if state.tail == nil {
            state.confirmed = current
            activityChanged(true)
        }
        state.revision += 1
        let revision = state.revision
        let predecessor = state.tail

        apply(desired)
        state.tail = Task { [self] in
            await OptimisticAction.perform(
                errorMessage: errorMessage,
                apply: {
                    guard state.revision == revision else { return }
                    apply(desired)
                },
                rollback: {
                    guard state.revision == revision, let confirmed = state.confirmed else { return }
                    apply(confirmed)
                },
                request: {
                    await predecessor?.value
                    return try await request(desired)
                },
                commit: { authoritative in
                    state.confirmed = authoritative
                    guard state.revision == revision else { return }
                    apply(authoritative)
                },
                reportFailure: reportFailure
            )
            if state.revision == revision {
                state.tail = nil
                activityChanged(false)
            }
        }
    }
}
