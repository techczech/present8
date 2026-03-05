import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit
import WebKit

@main
struct PresentApp: App {
    @State private var state: PresentationState
    @State private var presentationController = PresentationWindowController()
    @State private var server: RemoteServer

    init() {
        let s = PresentationState()
        let srv = RemoteServer()
        srv.start(state: s)
        _state = State(initialValue: s)
        _server = State(initialValue: srv)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .onReceive(NotificationCenter.default.publisher(for: .remotePlay)) { _ in
                    if !state.isPresenting {
                        presentationController.open(state: state)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .remoteStop)) { _ in
                    if state.isPresenting {
                        presentationController.close(state: state)
                    }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open...") {
                    FileDialogHelper.open(state: state)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Save As...") {
                    FileDialogHelper.save(state: state)
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Zoom In") {
                    state.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    state.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    state.zoomReset()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Deck") {
                Button("Warm Cache Now") {
                    state.triggerCacheWarmup()
                }
            }

            CommandMenu("YouTube") {
                Button("Sign In to YouTube...") {
                    YouTubeLoginWindowController.shared.open()
                }
            }

            CommandMenu("Presentation") {
                Button("Play") {
                    presentationController.open(state: state)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(state.totalPresentableCount == 0)
            }
        }
    }
}

enum FileDialogHelper {
    @MainActor
    static func open(state: PresentationState) {
        let panel = NSOpenPanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [.plainText, markdownType]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = state.loadFromFile(url)
        }
    }

    @MainActor
    static func save(state: PresentationState) {
        let panel = NSSavePanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType]
        panel.nameFieldStringValue = "presentation.md"
        if panel.runModal() == .OK, let url = panel.url {
            _ = state.saveToFile(url)
        }
    }
}

@MainActor
final class YouTubeLoginWindowController: NSObject, NSWindowDelegate {
    static let shared = YouTubeLoginWindowController()

    private var window: NSWindow?
    private weak var webView: WKWebView?

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to YouTube"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.webView = webView

        loadInitialSignInPage()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }

    private func loadInitialSignInPage() {
        guard let webView else { return }
        guard let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F") else {
            return
        }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30.0)
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        webView.load(request)
    }
}
