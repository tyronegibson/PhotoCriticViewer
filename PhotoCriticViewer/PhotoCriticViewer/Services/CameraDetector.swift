import AppKit
import Foundation
import Observation

/// Watches for a Hasselblad (or any camera/card) mounting as a USB volume —
/// confirmed to mount as a plain drive, not PTP, so no ImageCaptureCore
/// needed. Detection is protocol-free: any removable, ejectable volume that
/// contains at least one .3FR file is treated as a camera source. Both the
/// camera body and its card mount separately, so more than one can show up
/// at once.
@MainActor
@Observable
final class CameraDetector {
    struct CameraVolume: Identifiable, Hashable {
        let url: URL
        // True if the scan that found this volume also hit an unreadable file or folder on
        // it. Doesn't necessarily mean anything was missed (an unreadable directory's contents
        // are skipped, but the scan otherwise continues), but worth a visible flag rather than
        // swallowing it the way this used to.
        var hasScanWarnings: Bool = false
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    private(set) var detectedVolumes: [CameraVolume] = []

    private let workspace = NSWorkspace.shared
    // Tokens intentionally never removed — this detector is a single
    // @State instance owned by ContentView, living for the whole app
    // session, so there's no meaningful teardown moment to unregister at.
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    init() {
        rescan()
        mountObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A freshly mounted volume isn't always fully readable the instant the mount
            // notification fires -- a single scan at a fixed delay could run too early and
            // wrongly conclude there's no camera here. Retry a few times with increasing delay
            // instead of trusting the first attempt.
            for delay in [0.5, 1.5, 3.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.rescan() }
            }
        }
        unmountObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rescan() }
    }

    /// Ejects a detected camera/card volume. Failure (e.g. a file on it is
    /// still open somewhere) leaves detectedVolumes untouched — the
    /// didUnmountNotification observer is what actually removes it on success.
    @discardableResult
    func eject(_ volume: CameraVolume) -> Bool {
        (try? workspace.unmountAndEjectDevice(at: volume.url)) != nil
    }

    func rescan() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) else {
            detectedVolumes = []
            return
        }

        detectedVolumes = volumes.compactMap { url -> CameraVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            guard removable else { return nil }
            let scan = Self.containsRawFiles(at: url)
            guard scan.found else { return nil }
            return CameraVolume(url: url, hasScanWarnings: scan.hadWarnings)
        }
    }

    /// Full recursive scan — the X2D actually uses the standard camera
    /// layout `<volume>/DCIM/<roll>/*.3FR` (two levels of subfolders), not
    /// the one-level "archive dump" layout organize.py deals with, so a
    /// fixed-depth check missed it. Lazy enumeration means this returns as
    /// soon as the first match is found rather than walking the whole card.
    private static func containsRawFiles(at url: URL) -> (found: Bool, hadWarnings: Bool) {
        var hadWarnings = false
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in hadWarnings = true; return true }
        ) else { return (false, true) }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "3fr" { return (true, hadWarnings) }
        }
        return (false, hadWarnings)
    }
}
