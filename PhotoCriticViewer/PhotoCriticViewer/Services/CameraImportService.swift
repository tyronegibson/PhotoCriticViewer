import CryptoKit
import Foundation

/// Copies new .3FR files (and matching .xmp sidecars) from a detected camera
/// volume into a destination folder — read-only with respect to the camera's
/// card, only ever copies, never moves or deletes from it. Skips filenames
/// already present in the destination (top level or one level of
/// subfolders, matching organize.py's own discovery depth — files land in
/// date subfolders there after organizing) so re-plugging the same card
/// doesn't re-copy what's already been imported.
///
/// The X2D lays out its card as `DCIM/<roll>/*.3FR`, and the camera resets
/// its own file-number counter across rolls (e.g. after a reformat), so two
/// *different* photos from different roll folders can legitimately share a
/// filename. Flattening straight into one destination folder by filename
/// alone — which is what this used to do — silently treated the second one
/// as "already imported" and dropped it with no error, no matter how many
/// times the card was re-imported.
///
/// Matching on name + size alone (an earlier fix) narrowed that but didn't
/// close it: two different frames from two different rolls can share both a
/// filename *and* a byte size — RAW frames of similar content very plausibly
/// compress to the same size — and that combination was still treated as a
/// confirmed duplicate and skipped, silently, with no error. A same-name,
/// same-size match is now only a *candidate* duplicate: it's confirmed only
/// if a content check (see `partialDigest`) agrees too. A mismatch there is
/// copied under a disambiguated name and called out as a possible duplicate
/// rather than silently resolved either way.
enum CameraImportService {
    struct Result {
        var copied: [String] = []
        var skippedExisting: [String] = []
        var renamedForCollision: [(original: String, renamedTo: String)] = []
        // Same base name AND same size as something already imported, but a content check
        // showed it's actually a different photo -- copied under a disambiguated name (also
        // listed in renamedForCollision) but called out separately since this is exactly the
        // case that used to be silently dropped.
        var possibleDuplicates: [String] = []
        var failed: [(filename: String, reason: String)] = []
        // Folders/files the card scan itself couldn't read (permission or I/O error on the
        // card). Its contents are simply never visited -- the scan otherwise continues past
        // it to siblings -- so this doesn't necessarily mean photos were missed, but it's
        // worth surfacing instead of swallowing silently.
        var scanWarnings: [String] = []
    }

    static func importPhotos(from volume: URL, to destination: URL) -> Result {
        var result = Result()
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Index the destination by base name (ignoring the `__<roll>[_N]` suffix this
        // importer adds on a collision) so re-importing under a renamed name is recognized.
        // Keeps the URL of each candidate too, so an actual name+size collision can be
        // resolved with a content check instead of trusting size alone.
        var names = Set<String>()
        var existingByBase: [String: [(size: Int, url: URL)]] = [:]
        for file in existingFiles(in: destination) {
            names.insert(file.name)
            existingByBase[baseName(file.name), default: []].append((file.size, file.url))
        }
        let (sourceFiles, scanWarnings) = discoverRawFiles(at: volume)
        result.scanWarnings = scanWarnings

        for source in sourceFiles {
            let name = source.lastPathComponent
            let base = baseName(name.lowercased())
            // A file we can't read the size of is a failure, never a duplicate: 0/nil used to
            // compare equal to another unreadable/empty size and get silently skipped or, on
            // the write side, let a truncated copy pass verification.
            guard let sourceSize = fileSize(at: source) else {
                result.failed.append((name, "could not read file size"))
                continue
            }

            let sameSizeCandidates = (existingByBase[base] ?? []).filter { $0.size == sourceSize }
            var isDuplicate = false
            if !sameSizeCandidates.isEmpty {
                if let sourceDigest = partialDigest(at: source) {
                    isDuplicate = sameSizeCandidates.contains { partialDigest(at: $0.url) == sourceDigest }
                } else {
                    // Same name and size as something already here, but its content couldn't be
                    // checked -- don't guess either way; surface it so a person decides.
                    result.failed.append((name, "shares a name and size with an existing file; could not read it to confirm whether it's the same photo"))
                    continue
                }
            }

            if isDuplicate {
                result.skippedExisting.append(name)
                continue
            }

            var targetName = name
            let wasSameSizeCollision = !sameSizeCandidates.isEmpty
            if existingByBase[base] != nil {
                // Same base name as something already here (whether or not the size also
                // matched) -- a different photo from a different roll whose numbering
                // collided, so give it its own name.
                let rollHint = rollComponent(source.deletingLastPathComponent().lastPathComponent)
                targetName = uniqueDisambiguatedName(for: name, rollHint: rollHint, existingNames: names)
            }

            guard copy(source, named: targetName, into: destination, result: &result) else { continue }
            if targetName != name {
                result.renamedForCollision.append((original: name, renamedTo: targetName))
                if wasSameSizeCollision {
                    result.possibleDuplicates.append(name)
                }
            }
            names.insert(targetName.lowercased())
            existingByBase[base, default: []].append((sourceSize, destination.appendingPathComponent(targetName)))
        }

        return result
    }

    @discardableResult
    /// Crash-safe: each file is written to `<name>.partial`, size-checked against the source,
    /// then renamed into place, so an interrupted copy never leaves a truncated photo under its
    /// final name (which the next run would treat as already imported). XMP follows the same
    /// path, and a sidecar that fails to copy is now reported instead of silently dropped.
    private static func copy(_ source: URL, named name: String, into destination: URL, result: inout Result) -> Bool {
        let fm = FileManager.default
        let target = destination.appendingPathComponent(name)
        do {
            try copyVerified(from: source, to: target)
            result.copied.append(name)
            let xmp = source.deletingPathExtension().appendingPathExtension("xmp")
            let targetXmp = target.deletingPathExtension().appendingPathExtension("xmp")
            if fm.fileExists(atPath: xmp.path), !fm.fileExists(atPath: targetXmp.path) {
                do {
                    try copyVerified(from: xmp, to: targetXmp)
                } catch {
                    result.failed.append((xmp.lastPathComponent, "sidecar copy failed: \(error.localizedDescription)"))
                }
            }
            return true
        } catch {
            result.failed.append((name, error.localizedDescription))
            return false
        }
    }

    private static func copyVerified(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let partial = target.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: source, to: partial)
            // fileSize() treats 0 as invalid, so a truncated/empty copy (or an empty source)
            // throws here instead of a 0-byte "expected" comparing equal to a 0-byte "written".
            guard let expected = fileSize(at: source),
                  let written = fileSize(at: partial), written == expected else {
                throw CocoaError(.fileWriteUnknown)
            }
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// "b0004520__crystal o_2.3fr" -> "b0004520.3fr"
    private static func baseName(_ lowercasedName: String) -> String {
        guard let range = lowercasedName.range(of: "__") else { return lowercasedName }
        let ext = (lowercasedName as NSString).pathExtension
        return String(lowercasedName[..<range.lowerBound]) + "." + ext
    }

    /// `<stem>__<roll>.<ext>`, with a numeric suffix if that name is already taken.
    private static func uniqueDisambiguatedName(for name: String, rollHint: String, existingNames: Set<String>) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = "\(stem)__\(rollHint).\(ext)"
        var suffix = 2
        while existingNames.contains(candidate.lowercased()) {
            candidate = "\(stem)__\(rollHint)_\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    /// nil for an unreadable size AND for a 0-byte size -- a 0-byte read is never a valid RAW
    /// frame, and letting it through as a real size is what let an empty/truncated copy compare
    /// equal to another empty/truncated read and pass as "the same file" on either side.
    private static func fileSize(at url: URL) -> Int? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil, size > 0 else {
            return nil
        }
        return size
    }

    /// A roll/folder name made safe to embed in one filename: no separators, never "." or "..".
    private static func rollComponent(_ roll: String) -> String {
        let safe = roll
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return ["", ".", ".."].contains(safe) ? "unknown" : safe
    }

    /// How many .3FR files a volume currently has, for a quick preview before the user commits
    /// to an import, plus any card-read warnings from that same scan -- so a warning can be
    /// shown even if it left the count at (or near) 0, instead of just a greyed-out button.
    static func countRawFiles(at volume: URL) -> (count: Int, warnings: [String]) {
        let scan = discoverRawFiles(at: volume)
        return (scan.files.count, scan.warnings)
    }

    /// Must match photocritic/pipeline.py's MARKER_DIRNAME and DUPLICATES_DIRNAME. Photos in these
    /// folders don't count as already imported, so a re-plugged card restores them.
    private static let skippedDestinationFolders: Set<String> = ["_Marked_for_Deletion", "Dupe"]

    private static func existingFiles(in destination: URL) -> [(name: String, size: Int, url: URL)] {
        let fm = FileManager.default
        var files: [(name: String, size: Int, url: URL)] = []
        guard let topLevel = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return files
        }
        for entry in topLevel {
            if entry.pathExtension.lowercased() == "3fr" {
                if let size = fileSize(at: entry) { files.append((entry.lastPathComponent.lowercased(), size, entry)) }
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      !skippedDestinationFolders.contains(entry.lastPathComponent) {
                if let nested = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                    for n in nested where n.pathExtension.lowercased() == "3fr" {
                        if let size = fileSize(at: n) { files.append((n.lastPathComponent.lowercased(), size, n)) }
                    }
                }
            }
        }
        return files
    }

    /// Full recursive scan — the X2D uses the standard camera layout
    /// `<volume>/DCIM/<roll>/*.3FR` (two levels of subfolders), matching
    /// CameraDetector's scan depth.
    ///
    /// A directory FileManager can't open has its *contents* skipped (they're simply never
    /// visited) but the enumerator otherwise continues past it to siblings and the rest of the
    /// tree -- it does not abort the whole walk. An explicit `errorHandler` doesn't change that
    /// behavior; it just lets us see *which* directory was unreadable instead of it passing
    /// silently, which is the useful part given this runs against a camera card.
    private static func discoverRawFiles(at volume: URL) -> (files: [URL], warnings: [String]) {
        var found: [URL] = []
        var warnings: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: volume, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) else {
            return (found, ["could not open \(volume.lastPathComponent)"])
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "3fr" {
            found.append(fileURL)
        }
        return (found.sorted { $0.lastPathComponent < $1.lastPathComponent }, warnings)
    }

    /// Hashes the first and last 1 MB of a file (the whole file if smaller) rather than every
    /// byte, as a cheap-but-strong-enough content check. A full-file hash would be stronger but
    /// is too slow to run across an entire destination index on every card plugged in; this
    /// only ever runs on the handful of files that already collided on base name AND size,
    /// never on the whole library, so the cost is bounded by how often that coincidence happens.
    private static func partialDigest(at url: URL) -> String? {
        guard let size = fileSize(at: url) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 1_048_576
        var hasher = SHA256()
        do {
            if let head = try handle.read(upToCount: min(chunk, size)) {
                hasher.update(data: head)
            }
            if size > chunk {
                try handle.seek(toOffset: UInt64(size - chunk))
                if let tail = try handle.read(upToCount: chunk) {
                    hasher.update(data: tail)
                }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
