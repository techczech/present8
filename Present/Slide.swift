import Foundation

enum DeckMediaType: String, Codable, CaseIterable {
    case video
    case audio
}

struct MarkdownLink: Codable, Hashable {
    var label: String
    var target: String
}

enum DeckItemKind: Codable, Hashable {
    case web(url: String)
    case text(heading: String, markdown: String)
    case tweet(url: String)
    case youtube(url: String, fallbackLocalPath: String?)
    case localMedia(path: String, mediaType: DeckMediaType)
}

@Observable
final class DeckItem: Identifiable {
    let id: UUID
    var kind: DeckItemKind
    var manualLabel: String?
    var fetchedTitle: String?

    init(
        id: UUID = UUID(),
        kind: DeckItemKind,
        manualLabel: String? = nil,
        fetchedTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.manualLabel = manualLabel
        self.fetchedTitle = fetchedTitle
    }

    var isPresentable: Bool {
        true
    }

    var sourceURLString: String? {
        switch kind {
        case .web(let url), .tweet(let url), .youtube(let url, _):
            return url
        case .localMedia(let path, _):
            return path
        case .text:
            return nil
        }
    }

    var markdownTarget: String? {
        switch kind {
        case .web(let url), .tweet(let url), .youtube(let url, _):
            return url
        case .localMedia(let path, _):
            return path
        case .text:
            return nil
        }
    }

    var displayTitle: String {
        if let manualLabel, !manualLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return manualLabel
        }
        if let fetchedTitle, !fetchedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fetchedTitle
        }
        switch kind {
        case .text(let heading, _):
            return heading.isEmpty ? "Text Slide" : heading
        case .localMedia(let path, _):
            return URL(fileURLWithPath: path).lastPathComponent
        case .web(let url), .tweet(let url), .youtube(let url, _):
            if let parsed = URL(string: url), let host = parsed.host {
                return host
            }
            return url
        }
    }

    var sidebarTitle: String {
        switch kind {
        case .web(let url), .tweet(let url), .youtube(let url, _):
            if let fetchedTitle, !fetchedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fetchedTitle
            }
            if let host = URL(string: normalizeURLString(url))?.host, !host.isEmpty {
                return host
            }
            return compactURL(url)
        case .localMedia(let path, _):
            return URL(fileURLWithPath: path).lastPathComponent
        case .text(let heading, _):
            let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Text Slide" : trimmed
        }
    }

    var sidebarSubtitle: String {
        switch kind {
        case .web(let url), .tweet(let url), .youtube(let url, _):
            return compactURL(url)
        case .localMedia(let path, _):
            return compactURL(path)
        case .text(_, let markdown):
            let preview = markdown
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "Markdown"
            return preview
        }
    }

    var markdownDisplayLabel: String {
        guard let target = markdownTarget else {
            return displayTitle
        }
        return "[\(displayTitle)](\(target))"
    }

    var editableTarget: String {
        get {
            sourceURLString ?? ""
        }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .web:
                kind = .web(url: cleaned)
            case .tweet:
                kind = .tweet(url: cleaned)
            case .youtube(_, let fallback):
                kind = .youtube(url: cleaned, fallbackLocalPath: fallback)
            case .localMedia(_, let mediaType):
                kind = .localMedia(path: cleaned, mediaType: mediaType)
            case .text:
                break
            }
        }
    }

    var youtubeFallbackPath: String {
        get {
            if case .youtube(_, let fallback) = kind {
                return fallback ?? ""
            }
            return ""
        }
        set {
            guard case .youtube(let url, _) = kind else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            kind = .youtube(url: url, fallbackLocalPath: trimmed.isEmpty ? nil : trimmed)
        }
    }

    var mediaType: DeckMediaType {
        get {
            if case .localMedia(_, let mediaType) = kind {
                return mediaType
            }
            return .video
        }
        set {
            guard case .localMedia(let path, _) = kind else { return }
            kind = .localMedia(path: path, mediaType: newValue)
        }
    }

    var textHeading: String {
        get {
            if case .text(let heading, _) = kind {
                return heading
            }
            return ""
        }
        set {
            guard case .text(_, let markdown) = kind else { return }
            kind = .text(heading: newValue, markdown: markdown)
        }
    }

    var textMarkdownBody: String {
        get {
            if case .text(_, let markdown) = kind {
                return markdown
            }
            return ""
        }
        set {
            guard case .text(let heading, _) = kind else { return }
            kind = .text(heading: heading, markdown: newValue)
        }
    }

    func appendTextMarkdownLine(_ line: String) {
        guard case .text(let heading, let markdown) = kind else { return }
        if markdown.isEmpty {
            kind = .text(heading: heading, markdown: line)
        } else {
            kind = .text(heading: heading, markdown: "\(markdown)\n\(line)")
        }
    }

    func setYouTubeFallback(_ path: String?) {
        guard case .youtube(let url, _) = kind else { return }
        kind = .youtube(url: url, fallbackLocalPath: path)
    }

    var networkURL: URL? {
        switch kind {
        case .web(let url), .tweet(let url), .youtube(let url, _):
            if let parsed = URL(string: url), parsed.scheme != nil {
                return parsed
            }
            if let parsed = URL(string: "https://\(url)") {
                return parsed
            }
            return nil
        case .text, .localMedia:
            return nil
        }
    }

    var cacheKey: String {
        switch kind {
        case .web(let url):
            return "web:\(url)"
        case .text(let heading, let markdown):
            return "text:\(heading)|\(markdown)"
        case .tweet(let url):
            return "tweet:\(url)"
        case .youtube(let url, let fallback):
            return "youtube:\(url)|\(fallback ?? "")"
        case .localMedia(let path, let mediaType):
            return "media:\(mediaType.rawValue):\(path)"
        }
    }

    private func compactURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "file://"] {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        return value
    }

    private func normalizeURLString(_ raw: String) -> String {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return raw
        }
        return "https://\(raw)"
    }
}

@Observable
final class DeckSection: Identifiable {
    let id: UUID
    var title: String
    var items: [DeckItem]

    init(id: UUID = UUID(), title: String, items: [DeckItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }
}

@Observable
final class Deck {
    var sections: [DeckSection]

    init(sections: [DeckSection] = []) {
        self.sections = sections
    }
}

@MainActor
@Observable
final class PresentationState {
    var deck: Deck
    var currentItemID: UUID?
    var isPresenting: Bool = false
    var zoomLevel: Double = 1.0
    var loadedDeckURL: URL? = nil

    let bookmarks = SandboxBookmarks()
    let screenshotStore = SlideScreenshotStore()
    private let cacheWarmer = CacheWarmer()
    private let screenshotWarmer = SlideScreenshotWarmer()

    private static let autosaveMarkdownKey = "presentAutosavedDeckMarkdown"
    private static let autosaveDeckSourcePathKey = "presentAutosavedDeckSourcePath"
    private static let legacyAutosaveKey = "presentAutosavedURLs"
    private static let mainDeckFileName = "presentation.md"
    private static let screenshotsFolderName = "screenshots"

    init() {
        let restoredSourceURL: URL?
        if let sourcePath = UserDefaults.standard.string(forKey: Self.autosaveDeckSourcePathKey),
           !sourcePath.isEmpty {
            restoredSourceURL = URL(fileURLWithPath: sourcePath)
        } else {
            restoredSourceURL = nil
        }

        if let markdown = UserDefaults.standard.string(forKey: Self.autosaveMarkdownKey),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deck = DeckMarkdownParser.parseMarkdown(markdown, sourceURL: restoredSourceURL)
        } else if let urls = UserDefaults.standard.stringArray(forKey: Self.legacyAutosaveKey), !urls.isEmpty {
            deck = DeckMarkdownParser.parseLegacyURLList(urls)
        } else {
            deck = Deck(sections: [DeckSection(title: "Slides")])
        }

        loadedDeckURL = restoredSourceURL

        cacheWarmer.titleUpdate = { [weak self] itemID, title in
            guard let self else { return }
            if let item = self.item(withID: itemID) {
                item.fetchedTitle = title
                self.saveToDisk()
            }
        }

        ensureNonEmptyDeck()
        syncSelectionToCurrentItem()
    }

    var presentableItems: [DeckItem] {
        deck.sections.flatMap { $0.items }.filter { $0.isPresentable }
    }

    var currentPresentableItem: DeckItem? {
        guard let currentItemID else {
            return presentableItems.first
        }
        return presentableItems.first(where: { $0.id == currentItemID }) ?? presentableItems.first
    }

    var currentIndex: Int {
        guard let current = currentPresentableItem,
              let index = presentableItems.firstIndex(where: { $0.id == current.id }) else {
            return 0
        }
        return index
    }

    var totalPresentableCount: Int {
        presentableItems.count
    }

    var currentSlide: DeckItem? {
        currentPresentableItem
    }

    var deckFolderURL: URL? {
        loadedDeckURL?.deletingLastPathComponent()
    }

    var mainDeckFileURL: URL? {
        deckFolderURL?.appendingPathComponent(Self.mainDeckFileName, isDirectory: false)
    }

    var screenshotsFolderURL: URL? {
        deckFolderURL?.appendingPathComponent(Self.screenshotsFolderName, isDirectory: true)
    }

    func zoomIn() { zoomLevel = min(zoomLevel + 0.1, 5.0) }
    func zoomOut() { zoomLevel = max(zoomLevel - 0.1, 0.3) }
    func zoomReset() { zoomLevel = 1.0 }

    func goToNext() {
        let items = presentableItems
        guard !items.isEmpty else { return }
        guard let current = currentPresentableItem,
              let currentIndex = items.firstIndex(where: { $0.id == current.id }) else {
            currentItemID = items.first?.id
            return
        }
        currentItemID = items[(currentIndex + 1) % items.count].id
    }

    func goToPrevious() {
        let items = presentableItems
        guard !items.isEmpty else { return }
        guard let current = currentPresentableItem,
              let currentIndex = items.firstIndex(where: { $0.id == current.id }) else {
            currentItemID = items.first?.id
            return
        }
        currentItemID = items[(currentIndex - 1 + items.count) % items.count].id
    }

    func setCurrentItem(id: UUID?) {
        guard let id else {
            currentItemID = presentableItems.first?.id
            return
        }
        if presentableItems.contains(where: { $0.id == id }) {
            currentItemID = id
        }
    }

    func item(withID id: UUID) -> DeckItem? {
        for section in deck.sections {
            if let item = section.items.first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    func ensureNonEmptyDeck() {
        if deck.sections.isEmpty {
            deck.sections = [DeckSection(title: "Slides")]
        }
        if deck.sections.allSatisfy({ $0.items.isEmpty }) {
            deck.sections[0].items = [DeckItem(kind: .web(url: "https://example.com"))]
        }
    }

    func syncSelectionToCurrentItem() {
        if let current = currentPresentableItem {
            currentItemID = current.id
        } else {
            currentItemID = presentableItems.first?.id
        }
    }

    func markDirtyAndSave() {
        saveToDisk()
        screenshotWarmer.warm(
            items: presentableItems,
            deckBaseURL: deckFolderURL,
            bookmarks: bookmarks,
            screenshotStore: screenshotStore
        )
    }

    func applyLoadedDeck(_ newDeck: Deck, sourceURL: URL?) {
        deck = newDeck
        if let sourceURL {
            loadedDeckURL = sourceURL.standardizedFileURL
        }
        ensureNonEmptyDeck()
        syncSelectionToCurrentItem()
        if let folderURL = deckFolderURL {
            _ = screenshotStore.ensureScreenshotsDirectory(in: folderURL)
        }
        saveToDisk()
        triggerCacheWarmup()
    }

    func saveToDisk() {
        let markdown = DeckMarkdownParser.serialize(deck: deck)
        UserDefaults.standard.set(markdown, forKey: Self.autosaveMarkdownKey)
        UserDefaults.standard.set(loadedDeckURL?.path, forKey: Self.autosaveDeckSourcePathKey)
    }

    func loadFromDisk() {
        if let markdown = UserDefaults.standard.string(forKey: Self.autosaveMarkdownKey),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyLoadedDeck(DeckMarkdownParser.parseMarkdown(markdown, sourceURL: nil), sourceURL: nil)
        }
    }

    func loadFromFile(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        _ = bookmarks.storeAccess(for: standardizedURL.deletingLastPathComponent())
        guard let contents = try? String(contentsOf: standardizedURL, encoding: .utf8) else { return false }

        let deckFromFile: Deck
        if standardizedURL.pathExtension.lowercased() == "md" {
            deckFromFile = DeckMarkdownParser.parseMarkdown(contents, sourceURL: standardizedURL)
        } else {
            let urls = contents
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !urls.isEmpty else { return false }
            deckFromFile = DeckMarkdownParser.parseLegacyURLList(urls)
        }

        applyLoadedDeck(deckFromFile, sourceURL: standardizedURL)
        return true
    }

    func saveToFile(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        _ = bookmarks.storeAccess(for: standardizedURL.deletingLastPathComponent())
        let markdown = DeckMarkdownParser.serialize(deck: deck)
        do {
            try markdown.write(to: standardizedURL, atomically: true, encoding: .utf8)
            loadedDeckURL = standardizedURL
            if let folderURL = deckFolderURL {
                _ = screenshotStore.ensureScreenshotsDirectory(in: folderURL)
            }
            saveToDisk()
            triggerCacheWarmup()
            return true
        } catch {
            return false
        }
    }

    func openDeckFolder(_ folderURL: URL) -> Bool {
        let standardizedFolder = folderURL.standardizedFileURL
        _ = bookmarks.storeAccess(for: standardizedFolder)
        let mainDeckURL = standardizedFolder.appendingPathComponent(Self.mainDeckFileName, isDirectory: false)

        if FileManager.default.fileExists(atPath: mainDeckURL.path) {
            return loadFromFile(mainDeckURL)
        }

        applyLoadedDeck(Deck(sections: [DeckSection(title: "Slides")]), sourceURL: mainDeckURL)
        return saveToFile(mainDeckURL)
    }

    func saveDeck() -> Bool {
        guard let mainDeckFileURL else { return false }
        return saveToFile(mainDeckFileURL)
    }

    func saveDeckToFolder(_ folderURL: URL) -> Bool {
        let standardizedFolder = folderURL.standardizedFileURL
        _ = bookmarks.storeAccess(for: standardizedFolder)
        let mainDeckURL = standardizedFolder.appendingPathComponent(Self.mainDeckFileName, isDirectory: false)
        return saveToFile(mainDeckURL)
    }

    func resolveLocalPath(_ path: String) -> URL {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("file://"), let fileURL = URL(string: raw) {
            return fileURL
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        if let baseURL = deckFolderURL {
            return URL(fileURLWithPath: raw, relativeTo: baseURL).standardizedFileURL
        }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    func previewInfo(relativeOffset: Int, routePath: String) -> (available: Bool, url: String) {
        guard let item = presentableItem(relativeOffset: relativeOffset),
              let deckFolderURL,
              screenshotStore.existingScreenshotURL(for: item, deckFolderURL: deckFolderURL) != nil else {
            return (false, "")
        }

        let token = screenshotStore.previewToken(for: item)
        return (true, "\(routePath)?v=\(token)")
    }

    func previewImageData(relativeOffset: Int) -> Data? {
        guard let item = presentableItem(relativeOffset: relativeOffset),
              let deckFolderURL,
              let screenshotURL = screenshotStore.existingScreenshotURL(for: item, deckFolderURL: deckFolderURL) else {
            return nil
        }

        let accessibleURL = bookmarks.resolveAccessibleURL(for: screenshotURL) ?? screenshotURL
        return try? Data(contentsOf: accessibleURL)
    }

    func triggerCacheWarmup() {
        cacheWarmer.warm(items: presentableItems)
        screenshotWarmer.warm(
            items: presentableItems,
            deckBaseURL: deckFolderURL,
            bookmarks: bookmarks,
            screenshotStore: screenshotStore
        )
    }

    func prepareForPresentation() {
        triggerCacheWarmup()
    }

    private func presentableItem(relativeOffset: Int) -> DeckItem? {
        let items = presentableItems
        guard !items.isEmpty else { return nil }

        let base = currentIndex
        let wrapped = ((base + relativeOffset) % items.count + items.count) % items.count
        return items[wrapped]
    }
}
