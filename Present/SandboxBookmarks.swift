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

        if resolveStoredBookmark(forPath: key) != nil {
            return standardized
        }

        var ancestor = standardized.deletingLastPathComponent().standardizedFileURL
        while !ancestor.path.isEmpty, ancestor.path != "/" {
            if resolveStoredBookmark(forPath: ancestor.path) != nil {
                return standardized
            }
            let next = ancestor.deletingLastPathComponent().standardizedFileURL
            if next.path == ancestor.path { break }
            ancestor = next
        }

        return nil
    }

    func storeAccess(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let key = standardized.path

        if let bookmarkData = try? standardized.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarks[key] = bookmarkData
            persist()
        }

        _ = standardized.startAccessingSecurityScopedResource()
        return standardized
    }

    func promptAndStoreAccess(for suggestedURL: URL) -> URL? {
        let standardized = suggestedURL.standardizedFileURL

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = standardized.deletingLastPathComponent()
        panel.nameFieldStringValue = standardized.lastPathComponent

        guard panel.runModal() == .OK, let picked = panel.url else {
            return nil
        }

        return storeAccess(for: picked)
    }

    private func persist() {
        UserDefaults.standard.set(bookmarks, forKey: Self.storageKey)
    }

    private func resolveStoredBookmark(forPath path: String) -> URL? {
        guard let bookmarkData = bookmarks[path] else { return nil }

        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }

        if stale,
           let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[path] = refreshed
            persist()
        }

        _ = resolved.startAccessingSecurityScopedResource()
        return resolved
    }
}
