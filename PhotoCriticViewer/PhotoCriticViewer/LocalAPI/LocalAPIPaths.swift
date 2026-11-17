import Foundation

enum LocalAPIPathError: Error {
    case notAbsolute
    case outsideAllowedRoots
}

/// Resolves and validates a path given to the local API before it's used for anything.
///
/// The spec driving this feature said "accept absolute paths only ... reject paths outside
/// the user's home folder." PhotoCritic's actual photo library doesn't fit that: shoots and
/// the database live on an external volume (by default /Volumes/AI-/PhotoCritic, with
/// originals often on a separate archive volume too), entirely outside $HOME. A literal
/// home-only rule would make /open and /export unable to touch any real shoot, so this
/// generalizes the same intent -- deny arbitrary filesystem access by default -- to an
/// explicit, user-editable allowlist (LocalAPISettings.allowedRoots) instead of hardcoding
/// $HOME as the only option.
enum LocalAPIPaths {
    static func resolve(_ raw: String) -> Result<URL, LocalAPIPathError> {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(.notAbsolute) }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let standardizedPath = standardized.path

        for root in LocalAPISettings.allowedRoots {
            let rootExpanded = (root as NSString).expandingTildeInPath
            let rootStandardized = URL(fileURLWithPath: rootExpanded).standardizedFileURL.resolvingSymlinksInPath().path
            if standardizedPath == rootStandardized || standardizedPath.hasPrefix(rootStandardized + "/") {
                return .success(standardized)
            }
        }
        return .failure(.outsideAllowedRoots)
    }

    static func errorMessage(for error: LocalAPIPathError, raw: String) -> String {
        switch error {
        case .notAbsolute:
            return "path must be absolute (or start with ~): \(raw)"
        case .outsideAllowedRoots:
            let roots = LocalAPISettings.allowedRoots.joined(separator: ", ")
            return "path is outside the allowed roots (\(roots)) -- add it in Settings if this is expected: \(raw)"
        }
    }
}
