import Foundation
import WebKit

@MainActor
final class CacheWarmer: NSObject, WKNavigationDelegate {
    var titleUpdate: ((UUID, String) -> Void)?

    private let webView: WKWebView
    private var queue: [URL] = []
    private var timeoutTask: Task<Void, Never>?
    private var isActive = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func warm(items: [DeckItem]) {
        cancel()

        let candidates: [(UUID, URL)] = items.compactMap { item in
            guard let url = item.networkURL else { return nil }
            return (item.id, url)
        }

        guard !candidates.isEmpty else { return }

        let titleUpdate = self.titleUpdate
        for (itemID, url) in candidates {
            Task.detached(priority: .utility) {
                guard let title = await Self.fetchTitle(from: url) else { return }
                await MainActor.run {
                    titleUpdate?(itemID, title)
                }
            }
        }

        var seen: Set<String> = []
        queue = candidates.compactMap { _, url in
            let key = url.absoluteString
            if seen.contains(key) { return nil }
            seen.insert(key)
            return url
        }

        isActive = true
        loadNext()
    }

    func cancel() {
        isActive = false
        queue.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.stopLoading()
    }

    private func loadNext() {
        timeoutTask?.cancel()
        guard isActive else { return }

        guard !queue.isEmpty else {
            isActive = false
            return
        }

        let nextURL = queue.removeFirst()
        webView.load(URLRequest(url: nextURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8.0))

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                self?.loadNext()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadNext()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadNext()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadNext()
    }

    static func fetchTitle(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return nil
        }

        guard let html = String(data: data.prefix(200_000), encoding: .utf8) else {
            return nil
        }

        guard let title = extractTitle(fromHTML: html) else {
            return nil
        }

        let cleaned = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    private static func extractTitle(fromHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return String(html[titleRange])
    }
}
