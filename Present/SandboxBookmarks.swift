import Foundation
import AppKit

@MainActor
final class SandboxBookmarks {
    private static let storageKey = "presentSandboxBookmarks"
    private var bookmarks: [String: Data]

    init() {
        bookmarks = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Data] ?? [:]
    }

    func resolveAccessibleURL(for suggestedURL: URL) -> URL? {
        let standardized = suggestedURL.standardizedFileURL
        let key = standardized.path

        if FileManager.default.isReadableFile(atPath: key) {
            return standardized
        }

        if let bookmarkData = bookmarks[key] {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                bookmarkDataIsStale: &stale
            ) {
                if stale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    bookmarks[key] = refreshed
                    persist()
                }
                if resolved.startAccessingSecurityScopedResource() {
                    return resolved
                }
                return resolved
            }
        }

        return nil
    }

    func promptAndStoreAccess(for suggestedURL: URL) -> URL? {
        let standardized = suggestedURL.standardizedFileURL
        let key = standardized.path

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = standardized.deletingLastPathComponent()
        panel.nameFieldStringValue = standardized.lastPathComponent

        guard panel.runModal() == .OK, let picked = panel.url else {
            return nil
        }

        if let bookmarkData = try? picked.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[key] = bookmarkData
            persist()
        }

        _ = picked.startAccessingSecurityScopedResource()
        return picked
    }

    private func persist() {
        UserDefaults.standard.set(bookmarks, forKey: Self.storageKey)
    }
}
