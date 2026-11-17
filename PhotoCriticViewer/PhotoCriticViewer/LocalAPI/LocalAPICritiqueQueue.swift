import Foundation

/// Serializes /critique jobs so they run one at a time, in arrival order, without ever
/// answering a request with 409 the way /open and /export still do -- a job just waits its
/// turn here instead. Purely in-memory: job STATUS/history persistence is
/// LocalAPIJobStore's job (backed by SQLite). If the app restarts mid-queue, whatever was
/// waiting here is gone, same as whatever was actually running -- both get marked failed by
/// LocalAPIJobStore's own restart handling, not silently resumed.
actor LocalAPICritiqueQueue {
    static let shared = LocalAPICritiqueQueue()

    private var pending: [@Sendable () async -> Void] = []
    private var isDraining = false

    func enqueue(_ work: @Sendable @escaping () async -> Void) {
        pending.append(work)
        if !isDraining {
            isDraining = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let work = pending.removeFirst()
            await work()
        }
        isDraining = false
    }
}
