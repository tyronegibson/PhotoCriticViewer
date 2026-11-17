import AppKit

/// Starts/stops the local control API with the app's own lifecycle, rather than any one
/// window's -- the API should be reachable as long as the app is running, and should go away
/// cleanly (not leave a stray listening socket) when it quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force the token to exist from the moment the app launches, per spec ("on first
        // launch, generate a random token"), not lazily on the first API request.
        _ = LocalAPIAuth.token
        LocalAPIServer.shared.startIfEnabled()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalAPIServer.shared.stop()
    }
}
