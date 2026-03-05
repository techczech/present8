import SwiftUI
import WebKit
import AppKit

struct WebView: NSViewRepresentable {
    let item: DeckItem
    var pageZoom: Double = 1.0
    var deckBaseURL: URL?
    let bookmarks: SandboxBookmarks

    func makeCoordinator() -> Coordinator {
        Coordinator(bookmarks: bookmarks)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.startListeningForRemoteScroll()
        applyContent(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.currentDeckBaseURL = deckBaseURL
        applyContent(in: webView, coordinator: context.coordinator)
    }

    private func applyContent(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentDeckBaseURL = deckBaseURL

        let key = item.cacheKey
        if coordinator.lastLoadedKey == key {
            webView.pageZoom = pageZoom
            return
        }

        coordinator.lastLoadedKey = key
        webView.pageZoom = pageZoom

        switch item.kind {
        case .web(let rawURL):
            coordinator.resetYouTubeTracking()
            loadWeb(rawURL, in: webView, coordinator: coordinator)

        case .text(let heading, let markdown):
            coordinator.resetYouTubeTracking()
            let html = Self.textSlideHTML(heading: heading, markdownBody: markdown)
            webView.loadHTMLString(html, baseURL: nil)

        case .tweet(let tweetURL):
            coordinator.resetYouTubeTracking()
            coordinator.loadTweetEmbed(tweetURL: tweetURL, cacheKey: key, pageZoom: pageZoom)

        case .youtube(let youtubeURL, let fallbackPath):
            coordinator.startYouTubePlayback(youtubeURL: youtubeURL, fallbackPath: fallbackPath, pageZoom: pageZoom)

        case .localMedia(let path, let mediaType):
            coordinator.resetYouTubeTracking()
            coordinator.loadLocalMedia(path: path, mediaType: mediaType)
        }
    }

    private func loadWeb(_ rawURL: String, in webView: WKWebView, coordinator: Coordinator) {
        if Self.isImageURL(rawURL) {
            let resolved = Self.resolveURLString(rawURL)
            let html = """
            <!DOCTYPE html>
            <html><head><meta name=\"viewport\" content=\"width=device-width\">
            <style>
            * { margin: 0; padding: 0; overflow: hidden; }
            body { background: #000; display: flex; align-items: center; justify-content: center; width: 100vw; height: 100vh; }
            img { max-width: 100vw; max-height: 100vh; object-fit: contain; }
            </style>
            </head><body><img src=\"\(Self.escapeHTMLAttribute(resolved))\" alt=\"slide\"></body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

        guard let parsed = Self.resolvedURL(from: rawURL) else {
            webView.loadHTMLString(Self.errorHTML(message: "Invalid URL: \(rawURL)"), baseURL: nil)
            return
        }

        if webView.url != parsed {
            webView.load(URLRequest(url: parsed, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15.0))
        }
    }

    private static func isImageURL(_ raw: String) -> Bool {
        let lower = raw.lowercased().split(separator: "?").first.map(String.init) ?? raw.lowercased()
        return lower.hasSuffix(".png") ||
            lower.hasSuffix(".gif") ||
            lower.hasSuffix(".jpg") ||
            lower.hasSuffix(".jpeg") ||
            lower.hasSuffix(".webp") ||
            lower.hasSuffix(".svg")
    }

    private static func resolvedURL(from raw: String) -> URL? {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return parsed
        }
        return URL(string: "https://\(raw)")
    }

    private static func resolveURLString(_ raw: String) -> String {
        if let parsed = URL(string: raw), parsed.scheme != nil {
            return raw
        }
        return "https://\(raw)"
    }

    private static func textSlideHTML(heading: String, markdownBody: String) -> String {
        let markdownSource = markdownSource(heading: heading, body: markdownBody)
        let renderedHTML = markdownToStyledHTML(markdownSource)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <style>
          :root { color-scheme: dark; }
          body {
            margin: 0;
            padding: 6vh 8vw;
            background: #111;
            color: #fff;
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            line-height: 1.5;
          }
          .md { font-size: clamp(1rem, 2.15vw, 2rem); }
          .md h1, .md h2, .md h3, .md h4, .md h5, .md h6 { line-height: 1.2; margin: 0.25em 0 0.5em; }
          .md h1 { font-size: clamp(1.8rem, 5vw, 4rem); }
          .md pre, .md code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .md pre {
            background: #1a1a1a;
            padding: 0.8em 1em;
            border-radius: 10px;
            overflow-x: auto;
          }
          .md blockquote {
            border-left: 4px solid #2f5f8a;
            margin: 0.8em 0;
            padding: 0.1em 0 0.1em 0.8em;
            color: #d0d0d0;
          }
          .md table { border-collapse: collapse; width: 100%; margin: 1em 0; }
          .md th, .md td { border: 1px solid #333; padding: 0.4em 0.6em; }
          .md a { color: #7dc3ff; }
          .md img, .md video { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
          <article class=\"md\">\(renderedHTML)</article>
        </body>
        </html>
        """
    }

    private static func markdownSource(heading: String, body: String) -> String {
        let cleanHeading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .newlines)
        if cleanHeading.isEmpty {
            return cleanBody
        }
        if cleanBody.isEmpty {
            return "# \(cleanHeading)"
        }
        return "# \(cleanHeading)\n\n\(cleanBody)"
    }

    private static func markdownToStyledHTML(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return "<pre>\(escapeHTML(markdown))</pre>"
        }

        let ns = NSAttributedString(attributed)
        let range = NSRange(location: 0, length: ns.length)
        guard let htmlData = try? ns.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ),
        let html = String(data: htmlData, encoding: .utf8) else {
            return "<pre>\(escapeHTML(markdown))</pre>"
        }

        return extractBodyHTML(from: html)
    }

    private static func extractBodyHTML(from html: String) -> String {
        guard let bodyStart = html.range(of: "(?is)<body[^>]*>", options: .regularExpression),
              let bodyEnd = html.range(of: "(?is)</body>", options: .regularExpression) else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

    private static func localMediaHTML(fileURL: URL, mediaType: DeckMediaType) -> String {
        let source = escapeHTMLAttribute(fileURL.absoluteString)
        let mediaTag: String
        switch mediaType {
        case .video:
            mediaTag = "<video controls autoplay src=\"\(source)\"></video>"
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

    private static func tweetWrapperHTML(embedHTML: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <style>
          body {
            margin: 0;
            padding: 24px;
            background: #fff;
            display: flex;
            justify-content: center;
          }
        </style>
        </head>
        <body>
          \(embedHTML)
        </body>
        </html>
        """
    }

    private static func tweetFallbackHTML(tweetURL: String) -> String {
        let safeTweetURL = escapeHTMLAttribute(tweetURL)
        return tweetWrapperHTML(embedHTML: """
        <blockquote class=\"twitter-tweet\"><a href=\"\(safeTweetURL)\">\(safeTweetURL)</a></blockquote>
        <script async src=\"https://platform.twitter.com/widgets.js\" charset=\"utf-8\"></script>
        """)
    }

    private static func errorHTML(message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
        <style>
          body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #111; color: #fff; font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px; text-align: center; }
          .box { max-width: 40rem; }
        </style>
        </head>
        <body>
          <div class=\"box\">\(escapeHTML(message))</div>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastLoadedKey: String?
        var pendingYouTubeFallbackPath: String?
        var pendingYouTubeWatchURL: URL?
        var isAwaitingYouTubeEmbedResult = false
        var didFallbackToYouTubeWatchPage = false
        var currentDeckBaseURL: URL?

        private let bookmarks: SandboxBookmarks
        private var observer: NSObjectProtocol?
        private var activeTweetCacheKey: String?

        init(bookmarks: SandboxBookmarks) {
            self.bookmarks = bookmarks
        }

        func resetYouTubeTracking() {
            pendingYouTubeFallbackPath = nil
            pendingYouTubeWatchURL = nil
            isAwaitingYouTubeEmbedResult = false
            didFallbackToYouTubeWatchPage = false
        }

        func startYouTubePlayback(youtubeURL: String, fallbackPath: String?, pageZoom: Double) {
            guard let webView else { return }

            pendingYouTubeFallbackPath = fallbackPath
            didFallbackToYouTubeWatchPage = false
            webView.pageZoom = pageZoom

            if let playback = DeckMarkdownParser.youtubePlaybackURLs(from: youtubeURL) {
                pendingYouTubeWatchURL = playback.watchURL
                isAwaitingYouTubeEmbedResult = true
                webView.load(youtubeRequest(for: playback.embedURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20.0))
                return
            }

            isAwaitingYouTubeEmbedResult = false
            if let fallbackWatchURL = DeckMarkdownParser.youtubeWatchURL(from: youtubeURL) ?? WebView.resolvedURL(from: youtubeURL) {
                pendingYouTubeWatchURL = fallbackWatchURL
                didFallbackToYouTubeWatchPage = true
                webView.load(youtubeRequest(for: fallbackWatchURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20.0))
            } else if let fallbackPath {
                loadLocalMedia(path: fallbackPath, mediaType: DeckMarkdownParser.mediaType(for: fallbackPath) ?? .video)
            } else {
                webView.loadHTMLString(WebView.errorHTML(message: "Invalid YouTube URL"), baseURL: nil)
            }
        }

        func startListeningForRemoteScroll() {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: .remoteScroll,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let dy = notification.userInfo?["dy"] as? Double,
                      let webView = self?.webView else { return }
                webView.evaluateJavaScript("window.scrollBy(0, \(dy));", completionHandler: nil)
            }
        }

        func loadTweetEmbed(tweetURL: String, cacheKey: String, pageZoom: Double) {
            guard let webView else { return }
            webView.pageZoom = pageZoom
            activeTweetCacheKey = cacheKey

            guard let encoded = tweetURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let endpoint = URL(string: "https://publish.twitter.com/oembed?omit_script=false&url=\(encoded)") else {
                webView.loadHTMLString(WebView.tweetFallbackHTML(tweetURL: tweetURL), baseURL: nil)
                return
            }

            URLSession.shared.dataTask(with: endpoint) { [weak self] data, _, _ in
                guard let self else { return }

                var html: String?
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let embed = json["html"] as? String,
                   !embed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    html = embed
                }

                DispatchQueue.main.async {
                    guard self.activeTweetCacheKey == cacheKey,
                          let webView = self.webView else { return }

                    if let html {
                        webView.loadHTMLString(WebView.tweetWrapperHTML(embedHTML: html), baseURL: nil)
                    } else {
                        webView.loadHTMLString(WebView.tweetFallbackHTML(tweetURL: tweetURL), baseURL: nil)
                    }
                }
            }.resume()
        }

        func loadLocalMedia(path: String, mediaType: DeckMediaType) {
            guard let webView else { return }

            guard let fileURL = resolveAccessibleFileURL(for: path) else {
                webView.loadHTMLString(WebView.errorHTML(message: "Cannot access local media file: \(path)"), baseURL: nil)
                return
            }

            let html = WebView.localMediaHTML(fileURL: fileURL, mediaType: mediaType)
            webView.loadHTMLString(html, baseURL: fileURL.deletingLastPathComponent())
        }

        private func resolveAccessibleFileURL(for rawPath: String) -> URL? {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }

            let suggestedURL: URL
            if trimmed.hasPrefix("file://"), let parsed = URL(string: trimmed) {
                suggestedURL = parsed
            } else if trimmed.hasPrefix("/") {
                suggestedURL = URL(fileURLWithPath: trimmed)
            } else if let base = currentDeckBaseURL {
                suggestedURL = URL(fileURLWithPath: trimmed, relativeTo: base).standardizedFileURL
            } else {
                suggestedURL = URL(fileURLWithPath: trimmed).standardizedFileURL
            }

            if let accessible = bookmarks.resolveAccessibleURL(for: suggestedURL) {
                return accessible
            }

            return bookmarks.promptAndStoreAccess(for: suggestedURL)
        }

        private func handlePotentialYouTubeFallback() {
            guard let webView else { return }

            if isAwaitingYouTubeEmbedResult {
                isAwaitingYouTubeEmbedResult = false
                if !didFallbackToYouTubeWatchPage, let watchURL = pendingYouTubeWatchURL {
                    didFallbackToYouTubeWatchPage = true
                    // Full watch page fallback allows normal YouTube login/session.
                    webView.load(youtubeRequest(for: watchURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20.0))
                    return
                }
            }

            guard let fallbackPath = pendingYouTubeFallbackPath,
                  !fallbackPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            let mediaType = DeckMarkdownParser.mediaType(for: fallbackPath) ?? .video
            loadLocalMedia(path: fallbackPath, mediaType: mediaType)
            pendingYouTubeFallbackPath = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handlePotentialYouTubeFallback()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handlePotentialYouTubeFallback()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isAwaitingYouTubeEmbedResult else { return }

            let script = """
            (() => {
              const title = (document.title || '').toLowerCase();
              const body = ((document.body && document.body.innerText) || '').toLowerCase().slice(0, 12000);
              const hasErrorElement = !!document.querySelector('.ytp-error,.ytp-error-content-wrap,.html5-video-player.ytp-error');
              return (hasErrorElement ? '__YT_EMBED_ERROR__\\n' : '') + title + '\\n' + body;
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                guard self.isAwaitingYouTubeEmbedResult else { return }

                let inspected = (result as? String)?.lowercased() ?? ""
                if self.shouldFallbackFromYouTubeEmbed(inspected) {
                    self.handlePotentialYouTubeFallback()
                } else {
                    self.isAwaitingYouTubeEmbedResult = false
                }
            }
        }

        private func shouldFallbackFromYouTubeEmbed(_ inspectedContent: String) -> Bool {
            if inspectedContent.contains("__yt_embed_error__") {
                return true
            }

            let failureMarkers = [
                "this video is unavailable",
                "video unavailable",
                "video player configuration error",
                "error code: 152",
                "error code: 153",
                "error 152",
                "error 153",
                "watch on youtube",
                "playback on other websites has been disabled"
            ]

            return failureMarkers.contains { inspectedContent.contains($0) }
        }

        private func youtubeRequest(for url: URL, cachePolicy: URLRequest.CachePolicy, timeoutInterval: TimeInterval) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeoutInterval)
            let embedOrigin = DeckMarkdownParser.youTubeEmbedOrigin.absoluteString
            let referer = embedOrigin.hasSuffix("/") ? embedOrigin : "\(embedOrigin)/"
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue(embedOrigin, forHTTPHeaderField: "Origin")
            return request
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
