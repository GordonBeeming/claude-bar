import Foundation

/// Runs one piece of async work at a time: callers that arrive while it's in flight await the
/// same run instead of starting their own. A refresh spends a single-use refresh token, so two
/// overlapping refreshes means the second is rejected and the sign-in looks revoked.
actor SingleFlight<Value: Sendable> {
    private var current: Task<Value, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let current {
            return try await current.value
        }
        let task = Task { try await operation() }
        current = task
        // Only forget the run this call started: a caller resuming late must not clear a
        // newer run that began after this one finished.
        defer {
            if current == task {
                current = nil
            }
        }
        return try await task.value
    }
}
