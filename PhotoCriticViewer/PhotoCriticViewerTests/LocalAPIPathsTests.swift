import Testing
import Foundation
@testable import PhotoCriticViewer

/// LocalAPIPaths.resolve's allowlist check -- the security boundary for POST /open and
/// POST /export. Overrides LocalAPISettings.allowedRoots for the duration of each test and
/// restores it afterward, so these never depend on (or disturb) this machine's real settings.
///
/// .serialized: LocalAPISettings.allowedRoots is backed by UserDefaults, process-wide global
/// state -- Swift Testing runs a suite's tests in parallel by default, and two of these tests
/// each doing set-run-restore on that same global key at once raced each other for real
/// (observed as a flaky failure) before this trait was added.
@Suite(.serialized)
struct LocalAPIPathsTests {
    private func withAllowedRoots<T>(_ roots: [String], _ body: () throws -> T) rethrows -> T {
        let previous = LocalAPISettings.allowedRoots
        LocalAPISettings.allowedRoots = roots
        defer { LocalAPISettings.allowedRoots = previous }
        return try body()
    }

    @Test func rejectsARelativePath() {
        let result = LocalAPIPaths.resolve("relative/path")
        #expect(result.isFailure)
    }

    @Test func acceptsAPathInsideAnAllowedRoot() {
        withAllowedRoots(["/Volumes/AI-/PhotoCritic"]) {
            let result = LocalAPIPaths.resolve("/Volumes/AI-/PhotoCritic/database")
            #expect(result.isSuccess)
        }
    }

    @Test func rejectsAPathOutsideEveryAllowedRoot() {
        withAllowedRoots(["/Volumes/AI-/PhotoCritic"]) {
            let result = LocalAPIPaths.resolve("/etc/passwd")
            #expect(result.isFailure)
        }
    }

    @Test func doesNotFalsePositiveOnAPrefixMatchingRootNameButDifferentDirectory() {
        // "/Volumes/AI-2" should NOT be considered inside "/Volumes/AI-" just because the
        // string "/Volumes/AI-" is a textual prefix of it -- the check must respect path
        // component boundaries, not do a bare string prefix match.
        withAllowedRoots(["/Volumes/AI-"]) {
            let result = LocalAPIPaths.resolve("/Volumes/AI-2/something")
            #expect(result.isFailure)
        }
    }

    @Test func expandsATildePath() {
        // Deliberately not ~/Desktop (or Documents/Downloads/Pictures): those are
        // TCC-protected on macOS, and resolving/realpath-ing one without the test host app
        // holding that permission can behave oddly for reasons unrelated to what this test is
        // actually checking (tilde expansion). ~/Library isn't specially protected.
        withAllowedRoots([NSHomeDirectory()]) {
            let result = LocalAPIPaths.resolve("~/Library")
            #expect(result.isSuccess)
        }
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
    var isFailure: Bool { !isSuccess }
}
