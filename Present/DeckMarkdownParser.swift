import Foundation

enum DeckMarkdownParser {
    struct YouTubePlaybackURLs {
        let embedURL: URL
        let watchURL: URL
    }

    // Stable app-owned origin used for YouTube embed identity checks.
    static let youTubeEmbedOrigin = URL(string: "https://present.local")!

    static func parseLegacyURLList(_ urls: [String]) -> Deck {
        let items = urls.map { DeckItem(kind: classifyTarget($0)) }
        return Deck(sections: [DeckSection(title: "Slides", items: items)])
    }

    static func parseMarkdown(_ markdown: String, sourceURL: URL?) -> Deck {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)

        var sections: [DeckSection] = [DeckSection(title: "Slides")]
        var currentSectionIndex = 0
        var currentTextItemID: UUID?
        var lastYouTubeItemID: UUID?

        func currentSection() -> DeckSection {
            sections[currentSectionIndex]
        }

        func setCurrentSection(_ section: DeckSection) {
            if currentSectionIndex < sections.count {
                sections[currentSectionIndex] = section
            }
        }

        var isInFencedCodeBlock = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let sectionTitle = consumePrefix("# ", from: trimmed) {
                let cleanTitle = sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = cleanTitle.isEmpty ? "Untitled Section" : cleanTitle
                sections.append(DeckSection(title: title))
                currentSectionIndex = sections.count - 1
                currentTextItemID = nil
                isInFencedCodeBlock = false
                lastYouTubeItemID = nil
                continue
            }

            if let heading = consumePrefix("## ", from: trimmed) {
                let section = currentSection()
                let item = DeckItem(kind: .text(heading: heading.trimmingCharacters(in: .whitespacesAndNewlines), markdown: ""))
                section.items.append(item)
                setCurrentSection(section)
                currentTextItemID = item.id
                isInFencedCodeBlock = false
                lastYouTubeItemID = nil
                continue
            }

            if consumePrefix("fallback:", from: trimmed.lowercased()) != nil, currentTextItemID == nil {
                let original = String(trimmed.dropFirst("fallback:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let lastYouTubeItemID else { continue }
                let section = currentSection()
                if let index = section.items.firstIndex(where: { $0.id == lastYouTubeItemID }) {
                    section.items[index].setYouTubeFallback(original.isEmpty ? nil : original)
                    setCurrentSection(section)
                }
                continue
            }

            if let activeTextItemID = currentTextItemID {
                let section = currentSection()
                guard let textIndex = section.items.firstIndex(where: { $0.id == activeTextItemID }) else {
                    continue
                }

                if !isInFencedCodeBlock {
                    if let (label, target) = parseMarkdownLink(trimmed), !trimmed.isEmpty {
                        let item = DeckItem(kind: classifyTarget(target), manualLabel: label)
                        section.items.append(item)
                        setCurrentSection(section)
                        currentTextItemID = nil
                        isInFencedCodeBlock = false
                        if case .youtube = item.kind {
                            lastYouTubeItemID = item.id
                        } else {
                            lastYouTubeItemID = nil
                        }
                        continue
                    }

                    if looksLikeURLOrPath(trimmed), !trimmed.isEmpty {
                        let item = DeckItem(kind: classifyTarget(trimmed))
                        section.items.append(item)
                        setCurrentSection(section)
                        currentTextItemID = nil
                        isInFencedCodeBlock = false
                        if case .youtube = item.kind {
                            lastYouTubeItemID = item.id
                        } else {
                            lastYouTubeItemID = nil
                        }
                        continue
                    }
                }

                section.items[textIndex].appendTextMarkdownLine(rawLine)
                if isFenceDelimiter(trimmed) {
                    isInFencedCodeBlock.toggle()
                }
                setCurrentSection(section)
                continue
            }

            if trimmed.isEmpty {
                continue
            }

            if let bullet = consumePrefix("- ", from: trimmed) {
                let section = currentSection()
                let textItem = DeckItem(kind: .text(heading: "Notes", markdown: "- \(bullet)"))
                section.items.append(textItem)
                setCurrentSection(section)
                currentTextItemID = textItem.id
                isInFencedCodeBlock = false
                continue
            }

            if let (label, target) = parseMarkdownLink(trimmed) {
                let item = DeckItem(kind: classifyTarget(target), manualLabel: label)
                let section = currentSection()
                section.items.append(item)
                setCurrentSection(section)
                currentTextItemID = nil
                isInFencedCodeBlock = false
                if case .youtube = item.kind {
                    lastYouTubeItemID = item.id
                } else {
                    lastYouTubeItemID = nil
                }
                continue
            }

            if looksLikeURLOrPath(trimmed) {
                let item = DeckItem(kind: classifyTarget(trimmed))
                let section = currentSection()
                section.items.append(item)
                setCurrentSection(section)
                currentTextItemID = nil
                isInFencedCodeBlock = false
                if case .youtube = item.kind {
                    lastYouTubeItemID = item.id
                } else {
                    lastYouTubeItemID = nil
                }
                continue
            }

            let section = currentSection()
            let textItem = DeckItem(kind: .text(heading: trimmed, markdown: ""))
            section.items.append(textItem)
            setCurrentSection(section)
            currentTextItemID = textItem.id
            isInFencedCodeBlock = false
        }

        var cleanedSections = sections
            .map { section in
                DeckSection(title: section.title, items: section.items)
            }
            .filter { !$0.items.isEmpty || $0.title != "Slides" }

        if cleanedSections.isEmpty {
            cleanedSections = [DeckSection(title: "Slides")]
        }

        _ = sourceURL

        return Deck(sections: cleanedSections)
    }

    static func serialize(deck: Deck) -> String {
        var output: [String] = []

        for section in deck.sections {
            output.append("# \(section.title)")
            output.append("")

            for item in section.items {
                switch item.kind {
                case .text(let heading, let markdown):
                    output.append("## \(heading)")
                    if !markdown.trimmingCharacters(in: .newlines).isEmpty {
                        output.append(contentsOf: markdown.components(separatedBy: .newlines))
                    }

                case .web(let url), .tweet(let url):
                    output.append(markdownLine(label: item.manualLabel, target: url))

                case .youtube(let url, let fallbackLocalPath):
                    output.append(markdownLine(label: item.manualLabel, target: url))
                    if let fallbackLocalPath, !fallbackLocalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        output.append("fallback: \(fallbackLocalPath)")
                    }

                case .localMedia(let path, _):
                    output.append(markdownLine(label: item.manualLabel, target: path))
                }

                output.append("")
            }
        }

        return output.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    static func classifyTarget(_ target: String) -> DeckItemKind {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)

        if isTweetURL(trimmed) {
            return .tweet(url: trimmed)
        }

        if isYouTubeURL(trimmed) {
            return .youtube(url: trimmed, fallbackLocalPath: nil)
        }

        if let mediaType = mediaType(for: trimmed) {
            return .localMedia(path: trimmed, mediaType: mediaType)
        }

        return .web(url: trimmed)
    }

    static func isTweetURL(_ raw: String) -> Bool {
        guard let url = resolvedURL(from: raw), let host = url.host?.lowercased() else { return false }
        guard host.contains("twitter.com") || host.contains("x.com") else { return false }
        return url.path.lowercased().contains("/status/")
    }

    static func isYouTubeURL(_ raw: String) -> Bool {
        youtubePlaybackURLs(from: raw) != nil
    }

    static func youtubeEmbedURL(from raw: String) -> URL? {
        youtubePlaybackURLs(from: raw)?.embedURL
    }

    static func youtubeWatchURL(from raw: String) -> URL? {
        youtubePlaybackURLs(from: raw)?.watchURL
    }

    static func youtubePlaybackURLs(from raw: String) -> YouTubePlaybackURLs? {
        guard let url = resolvedYouTubeURL(from: raw) else { return nil }
        guard let host = url.host?.lowercased(), isYouTubeHost(host) else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let listID = queryItems.first(where: { $0.name == "list" })?.value?.nonEmpty
        let startSeconds = parseYouTubeStartSeconds(from: queryItems)

        var videoID: String? = nil
        let path = url.path
        let pathParts = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if host.contains("youtu.be"), let first = pathParts.first {
            videoID = first.nonEmpty
        } else {
            let lowerPath = path.lowercased()

            if lowerPath == "/watch" {
                videoID = queryItems.first(where: { $0.name == "v" })?.value?.nonEmpty
            } else if lowerPath.hasPrefix("/shorts/"), pathParts.count >= 2 {
                videoID = pathParts[1].nonEmpty
            } else if lowerPath.hasPrefix("/live/"), pathParts.count >= 2 {
                videoID = pathParts[1].nonEmpty
            } else if lowerPath.hasPrefix("/embed/"), pathParts.count >= 2 {
                videoID = pathParts[1].nonEmpty
            } else if lowerPath.hasPrefix("/v/"), pathParts.count >= 2 {
                videoID = pathParts[1].nonEmpty
            } else if lowerPath == "/playlist" {
                videoID = nil
            }
        }

        let watchURL: URL
        let embedURL: URL

        if let videoID {
            var watchComponents = URLComponents(string: "https://www.youtube.com/watch")
            var watchQuery: [URLQueryItem] = [URLQueryItem(name: "v", value: videoID)]
            if let listID {
                watchQuery.append(URLQueryItem(name: "list", value: listID))
            }
            if let startSeconds {
                watchQuery.append(URLQueryItem(name: "t", value: String(startSeconds)))
            }
            watchComponents?.queryItems = watchQuery
            guard let watch = watchComponents?.url else { return nil }
            watchURL = watch

            var embedComponents = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")
            var embedQuery: [URLQueryItem] = [
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "enablejsapi", value: "1"),
                URLQueryItem(name: "origin", value: youTubeEmbedOrigin.absoluteString)
            ]
            if let listID {
                embedQuery.append(URLQueryItem(name: "list", value: listID))
            }
            if let startSeconds {
                embedQuery.append(URLQueryItem(name: "start", value: String(startSeconds)))
            }
            embedComponents?.queryItems = embedQuery
            guard let embed = embedComponents?.url else { return nil }
            embedURL = embed
        } else if let listID {
            var watchComponents = URLComponents(string: "https://www.youtube.com/playlist")
            watchComponents?.queryItems = [URLQueryItem(name: "list", value: listID)]
            guard let watch = watchComponents?.url else { return nil }
            watchURL = watch

            var embedComponents = URLComponents(string: "https://www.youtube.com/embed/videoseries")
            var embedQuery: [URLQueryItem] = [
                URLQueryItem(name: "list", value: listID),
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "enablejsapi", value: "1"),
                URLQueryItem(name: "origin", value: youTubeEmbedOrigin.absoluteString)
            ]
            if let startSeconds {
                embedQuery.append(URLQueryItem(name: "start", value: String(startSeconds)))
            }
            embedComponents?.queryItems = embedQuery
            guard let embed = embedComponents?.url else { return nil }
            embedURL = embed
        } else {
            return nil
        }

        return YouTubePlaybackURLs(embedURL: embedURL, watchURL: watchURL)
    }

    static func mediaType(for raw: String) -> DeckMediaType? {
        let lower = raw.lowercased().split(separator: "?").first.map(String.init) ?? raw.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v") || lower.hasSuffix(".webm") {
            return .video
        }
        if lower.hasSuffix(".mp3") || lower.hasSuffix(".m4a") || lower.hasSuffix(".wav") || lower.hasSuffix(".aac") || lower.hasSuffix(".flac") {
            return .audio
        }
        return nil
    }

    private static func parseMarkdownLink(_ line: String) -> (String, String)? {
        guard line.hasPrefix("["),
              let closingBracket = line.firstIndex(of: "]"),
              line.distance(from: line.startIndex, to: closingBracket) > 1 else {
            return nil
        }

        let afterBracket = line.index(after: closingBracket)
        guard afterBracket < line.endIndex,
              line[afterBracket] == "(",
              line.hasSuffix(")") else {
            return nil
        }

        let label = String(line[line.index(after: line.startIndex)..<closingBracket])
        let targetStart = line.index(after: afterBracket)
        let targetEnd = line.index(before: line.endIndex)
        guard targetStart <= targetEnd else { return nil }
        let target = String(line[targetStart..<targetEnd])

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedTarget.isEmpty else { return nil }

        return (trimmedLabel, trimmedTarget)
    }

    private static func markdownLine(label: String?, target: String) -> String {
        let cleanedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cleanedTarget
        }
        return "[\(label)](\(cleanedTarget))"
    }

    private static func consumePrefix(_ prefix: String, from line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func looksLikeURLOrPath(_ line: String) -> Bool {
        if line.hasPrefix("http://") || line.hasPrefix("https://") || line.hasPrefix("file://") {
            return true
        }
        if line.contains(".") && !line.contains(" ") {
            return true
        }
        if line.hasPrefix("/") || line.hasPrefix("./") || line.hasPrefix("../") {
            return true
        }
        return false
    }

    private static func isFenceDelimiter(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func resolvedURL(from raw: String) -> URL? {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return parsed
        }
        return URL(string: "https://\(raw)")
    }

    private static func resolvedYouTubeURL(from raw: String) -> URL? {
        guard var url = resolvedURL(from: raw) else { return nil }

        if url.path.lowercased() == "/attribution_link",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let encodedU = components.queryItems?.first(where: { $0.name == "u" })?.value?.removingPercentEncoding,
           let nested = URL(string: encodedU, relativeTo: URL(string: "https://www.youtube.com"))?.absoluteURL {
            url = nested
        }

        return url
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com")
    }

    private static func parseYouTubeStartSeconds(from queryItems: [URLQueryItem]) -> Int? {
        let raw = queryItems.first(where: { ["start", "t", "time_continue"].contains($0.name.lowercased()) })?.value?.lowercased()
        guard let raw, !raw.isEmpty else { return nil }

        if let value = Int(raw) {
            return max(value, 0)
        }

        var total = 0
        var number = ""
        for ch in raw {
            if ch.isNumber {
                number.append(ch)
                continue
            }
            guard let value = Int(number) else { continue }
            switch ch {
            case "h":
                total += value * 3600
            case "m":
                total += value * 60
            case "s":
                total += value
            default:
                break
            }
            number = ""
        }

        if total > 0 {
            return total
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
