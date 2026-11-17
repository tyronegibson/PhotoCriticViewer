import Foundation

/// Runs a blocking SQLite read off the main actor, then applies its result on the main actor.
/// The connection's busy_timeout can block for seconds while the Python pipeline holds the write
/// lock, so views must not call PhotoCriticDatabase synchronously from their body or handlers.
@MainActor
func runDatabaseQuery<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T,
    apply: @escaping @MainActor (Result<T, Error>) -> Void
) {
    Task {
        let result = await Task.detached { Result { try work() } }.value
        apply(result)
    }
}
