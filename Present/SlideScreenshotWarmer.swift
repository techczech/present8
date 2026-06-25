import Foundation
import WebKit
import CoreGraphics

@MainActor
final class SlideScreenshotWarmer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var queue: [DeckItem] = []
    private var timeoutTask: Task<Void, Never>?
    private var deckBaseURL: URL?
    private var bookmarks: SandboxBookmarks?
    private var screenshotStore: SlideScreenshotStore?
    private var currentItem: DeckItem?
    private var didHandleCurrent = false
    private var generation = UUID()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func warm(items: [DeckItem], deckBaseURL: URL?, bookmarks: SandboxBookmarks, screenshotStore: SlideScreenshotStore) {
        cancel()

        guard let deckBaseURL else { return }
        self.deckBaseURL = deckBaseURL
        self.bookmarks = bookmarks
        self.screenshotStore = screenshotStore

        queue = items.filter { item in
            screenshotStore.existingScreenshotURL(for: item, deckFolderURL: deckBaseURL) == nil
        }

        guard !queue.isEmpty else { return }

        generation = UUID()
        loadNext()
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        queue.removeAll()
        currentItem = nil
        didHandleCurrent = false
        webView.stopLoading()
    }

    private func loadNext() {
        timeoutTask?.cancel()
        timeoutTask = nil
        didHandleCurrent = false

        guard !queue.isEmpty else {
            currentItem = nil
            return
        }

        let item = queue.removeFirst()
        currentItem = item
        webView.stopLoading()

        guard load(item: item) else {
            finishCurrent(capture: false)
            return
        }

        let currentGeneration = generation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await MainActor.run {
                guard let self,
                      self.generation == currentGeneration else { return }
                self.finishCurrent(capture: true)
            }
        }
    }

    private func load(item: DeckItem) -> Bool {
        switch item.kind {
        case .text(let heading, let markdown):
            webView.loadHTMLString(textSlideHTML(heading: heading, markdownBody: markdown), baseURL: nil)
            return true

        case .localMedia(let path, let mediaType):
            guard let fileURL = resolveAccessibleFileURL(for: path) else { return false }
            webView.loadHTMLString(localMediaHTML(fileURL: fileURL, mediaType: mediaType), baseURL: fileURL.deletingLastPathComponent())
            return true

        case .web(let rawURL):
            return loadURLBackedSlide(rawURL)

        case .tweet(let tweetURL):
            return loadURLBackedSlide(tweetURL)

        case .youtube(let youtubeURL, _):
            let watchURL = DeckMarkdownParser.youtubeWatchURL(from: youtubeURL)
            return loadURLBackedSlide(watchURL?.absoluteString ?? youtubeURL)
        }
    }

    private func loadURLBackedSlide(_ rawURL: String) -> Bool {
        guard let url = resolveURLForSlide(rawURL) else { return false }

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return true
        }

        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15.0))
        return true
    }

    private func resolveURLForSlide(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            if parsed.isFileURL {
                return resolveAccessibleFileURL(for: trimmed)
            }
            return parsed
        }

        if let localURL = resolveAccessibleLocalRelativeFileURL(for: trimmed) {
            return localURL
        }

        return URL(string: "https://\(trimmed)")
    }

    private func resolveAccessibleLocalRelativeFileURL(for rawPath: String) -> URL? {
        guard let deckBaseURL else { return nil }

        let candidate = URL(fileURLWithPath: rawPath, relativeTo: deckBaseURL).standardizedFileURL
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return bookmarks?.resolveAccessibleURL(for: candidate) ?? candidate
    }

    private func resolveAccessibleFileURL(for rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let suggestedURL: URL
        if trimmed.hasPrefix("file://"), let parsed = URL(string: trimmed) {
            suggestedURL = parsed.standardizedFileURL
        } else if trimmed.hasPrefix("/") {
            suggestedURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else if let deckBaseURL {
            suggestedURL = URL(fileURLWithPath: trimmed, relativeTo: deckBaseURL).standardizedFileURL
        } else {
            suggestedURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        if let accessible = bookmarks?.resolveAccessibleURL(for: suggestedURL) {
            return accessible
        }

        return FileManager.default.isReadableFile(atPath: suggestedURL.path) ? suggestedURL : nil
    }

    private func finishCurrent(capture: Bool) {
        guard !didHandleCurrent else { return }
        didHandleCurrent = true
        timeoutTask?.cancel()
        timeoutTask = nil

        guard capture,
              let item = currentItem,
              let deckBaseURL,
              let screenshotStore else {
            currentItem = nil
            loadNext()
            return
        }

        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1280
        config.afterScreenUpdates = true

        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            if let image,
               let jpegData = screenshotStore.jpegData(from: image) {
                _ = screenshotStore.writeJPEG(jpegData, for: item, deckFolderURL: deckBaseURL)
            }
            self.currentItem = nil
            self.loadNext()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishCurrent(capture: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishCurrent(capture: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishCurrent(capture: false)
    }

    private func textSlideHTML(heading: String, markdownBody: String) -> String {
        let title = escapeHTML(heading.trimmingCharacters(in: .whitespacesAndNewlines))
        let body = escapeHTML(markdownBody)
            .replacingOccurrences(of: "\n", with: "<br>")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <style>
          body {
            margin: 0;
            min-height: 100vh;
            padding: 6vh 8vw;
            background: #111;
            color: #fff;
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            line-height: 1.45;
          }
          h1 { margin: 0 0 0.7em; font-size: clamp(1.8rem, 4.8vw, 3.6rem); }
          .body { font-size: clamp(1rem, 2.2vw, 1.8rem); }
        </style>
        </head>
        <body>
          <h1>\(title.isEmpty ? "Text Slide" : title)</h1>
          <div class=\"body\">\(body)</div>
        </body>
        </html>
        """
    }

    private func localMediaHTML(fileURL: URL, mediaType: DeckMediaType) -> String {
        let source = escapeHTMLAttribute(fileURL.absoluteString)
        let mediaTag: String
        switch mediaType {
        case .video:
            mediaTag = "<video controls autoplay muted src=\"\(source)\"></video>"
        case .audio:
            mediaTag = "<audio controls autoplay src=\"\(source)\"></audio>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <style>
          body {
            margin: 0;
            background: #000;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
          }
          video {
            width: 100vw;
            height: 100vh;
            object-fit: contain;
            background: #000;
          }
          audio {
            width: min(80vw, 720px);
          }
        </style>
        </head>
        <body>
          \(mediaTag)
        </body>
        </html>
        """
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
