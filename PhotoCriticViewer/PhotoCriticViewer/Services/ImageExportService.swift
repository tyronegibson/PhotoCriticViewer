import Foundation

/// Copies original RAW files (never previews) to a destination folder chosen
/// by the user. Read-only with respect to the shoot — sources are never
/// modified or moved, only copied.
enum ImageExportService {
    struct Result {
        var copied: [String] = []
        var skippedExisting: [String] = []
        var failed: [(filename: String, reason: String)] = []
    }

    static func export(items: [PhotoGridItem], to destination: URL) -> Result {
        var result = Result()
        let fm = FileManager.default

        for item in items {
            let source = URL(fileURLWithPath: item.fullPath)
            let target = destination.appendingPathComponent(source.lastPathComponent)

            guard fm.fileExists(atPath: source.path) else {
                result.failed.append((item.filename, "Source file not found"))
                continue
            }
            if fm.fileExists(atPath: target.path) {
                result.skippedExisting.append(item.filename)
                continue
            }
            do {
                try fm.copyItem(at: source, to: target)
                result.copied.append(item.filename)
            } catch {
                result.failed.append((item.filename, error.localizedDescription))
            }
        }

        return result
    }

    /// Copies the analysis-resolution preview JPEGs (not the RAW originals) —
    /// already the right size for social/client-review delivery, no RAW
    /// re-decode needed. `items` order determines numbering when `numbered`.
    /// Numbered names use the shoot name rather than the original (often
    /// camera-generated, e.g. "B0002660") filename, since these go out to
    /// clients who don't need to see that.
    static func exportPreviews(items: [PhotoGridItem], to destination: URL, shootName: String, numbered: Bool) -> Result {
        var result = Result()
        let fm = FileManager.default
        let safeShootName = shootName.replacingOccurrences(of: "/", with: "-")

        for (index, item) in items.enumerated() {
            guard let previewPath = item.previewPath else {
                result.failed.append((item.filename, "No preview available"))
                continue
            }
            let source = WorkspaceConfig.previewURL(forPreviewPath: previewPath)
            guard fm.fileExists(atPath: source.path) else {
                result.failed.append((item.filename, "Preview file not found"))
                continue
            }

            let targetName = numbered
                ? "\(safeShootName)_\(String(format: "%03d", index + 1)).\(source.pathExtension)"
                : source.lastPathComponent
            let target = destination.appendingPathComponent(targetName)

            if fm.fileExists(atPath: target.path) {
                result.skippedExisting.append(item.filename)
                continue
            }
            do {
                try fm.copyItem(at: source, to: target)
                result.copied.append(item.filename)
            } catch {
                result.failed.append((item.filename, error.localizedDescription))
            }
        }

        return result
    }
}
