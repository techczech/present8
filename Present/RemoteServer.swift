import Foundation
import Network

extension Notification.Name {
    static let remotePlay = Notification.Name("remotePlay")
    static let remoteStop = Notification.Name("remoteStop")
    static let remoteScroll = Notification.Name("remoteScroll")
}

@MainActor
final class RemoteServer {
    private var listener: NWListener?
    private var state: PresentationState?

    func start(state: PresentationState) {
        self.state = state
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: 9123)
        } catch {
            print("RemoteServer: failed to create listener: \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }
        listener?.stateUpdateHandler = { newState in
            print("RemoteServer: \(newState)")
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                let responseData = self.route(request)
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func route(_ raw: String) -> Data {
        let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let fullPath = parts.count >= 2 ? String(parts[1]) : "/"
        let path = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        switch path {
        case "/next":
            state?.goToNext()
            return jsonResponse("ok")
        case "/prev":
            state?.goToPrevious()
            return jsonResponse("ok")
        case "/play":
            NotificationCenter.default.post(name: .remotePlay, object: nil)
            return jsonResponse("ok")
        case "/stop":
            NotificationCenter.default.post(name: .remoteStop, object: nil)
            return jsonResponse("ok")
        case "/zoomin":
            state?.zoomIn()
            return jsonResponse("ok")
        case "/zoomout":
            state?.zoomOut()
            return jsonResponse("ok")
        case "/scroll":
            if let query = fullPath.split(separator: "?", maxSplits: 1).last,
               let dyParam = query.split(separator: "=").last,
               let dy = Double(dyParam) {
                NotificationCenter.default.post(name: .remoteScroll, object: nil, userInfo: ["dy": dy])
            }
            return jsonResponse("ok")
        case "/status":
            return statusResponse()
        case "/preview/current":
            return previewResponse(relativeOffset: 0)
        case "/preview/next":
            return previewResponse(relativeOffset: 1)
        default:
            return htmlResponse()
        }
    }

    private func jsonResponse(_ status: String) -> Data {
        let body = Data("{\"status\":\"\(status)\"}".utf8)
        return httpResponse(contentType: "application/json", body: body)
    }

    private func statusResponse() -> Data {
        let index = state?.currentIndex ?? 0
        let total = state?.totalPresentableCount ?? 0
        let presenting = state?.isPresenting ?? false
        let slideURL = state?.currentSlide?.sourceURLString ?? ""

        let currentPreview: (available: Bool, url: String) = state?.previewInfo(relativeOffset: 0, routePath: "/preview/current") ?? (available: false, url: "")
        let nextPreview: (available: Bool, url: String) = state?.previewInfo(relativeOffset: 1, routePath: "/preview/next") ?? (available: false, url: "")

        let payload: [String: Any] = [
            "slide": total == 0 ? 0 : index + 1,
            "total": total,
            "presenting": presenting,
            "url": slideURL,
            "currentPreviewAvailable": currentPreview.available,
            "currentPreviewURL": currentPreview.url,
            "nextPreviewAvailable": nextPreview.available,
            "nextPreviewURL": nextPreview.url
        ]

        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        return httpResponse(contentType: "application/json", body: body)
    }

    private func previewResponse(relativeOffset: Int) -> Data {
        guard let imageData = state?.previewImageData(relativeOffset: relativeOffset) else {
            return notFoundResponse()
        }
        return httpResponse(
            contentType: "image/jpeg",
            body: imageData,
            extraHeaders: [
                "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                "Pragma": "no-cache"
            ]
        )
    }

    private func notFoundResponse() -> Data {
        httpResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
    }

    private func htmlResponse() -> Data {
        let body = Data(Self.htmlPage.utf8)
        return httpResponse(contentType: "text/html; charset=utf-8", body: body)
    }

    private func httpResponse(
        status: String = "200 OK",
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Connection: close\r\n"
        for (key, value) in extraHeaders {
            headers += "\(key): \(value)\r\n"
        }
        headers += "\r\n"

        var response = Data(headers.utf8)
        response.append(body)
        return response
    }

    static let htmlPage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <title>Present Remote</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        background: #1a1a2e; color: #eee;
        display: flex; flex-direction: column; align-items: center;
        min-height: 100dvh; padding: 16px; gap: 14px;
        -webkit-user-select: none; user-select: none;
      }
      #status { font-size: 1.4rem; font-weight: 600; text-align: center; min-height: 1.6em; }
      #url { font-size: 0.82rem; opacity: 0.45; word-break: break-all; text-align: center; max-width: 95vw; }
      .preview-row {
        width: 100%;
        max-width: 460px;
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 10px;
      }
      .preview-card {
        background: #121a33;
        border: 1px solid #243153;
        border-radius: 12px;
        padding: 8px;
        display: flex;
        flex-direction: column;
        gap: 6px;
      }
      .preview-label { font-size: 0.72rem; letter-spacing: 0.04em; opacity: 0.72; }
      .preview-image-wrap {
        width: 100%;
        aspect-ratio: 16 / 9;
        border-radius: 8px;
        overflow: hidden;
        background: #090d1d;
        display: flex;
        align-items: center;
        justify-content: center;
      }
      .preview-image {
        width: 100%;
        height: 100%;
        object-fit: cover;
        display: none;
      }
      .preview-empty {
        font-size: 0.72rem;
        opacity: 0.55;
        text-align: center;
      }
      .nav-row { display: flex; gap: 12px; width: 100%; max-width: 460px; }
      button {
        flex: 1; padding: 20px 10px; font-size: 1.35rem; font-weight: 600;
        border: none; border-radius: 14px; cursor: pointer;
        transition: transform 0.1s, opacity 0.1s;
        min-height: 72px;
      }
      button:active { transform: scale(0.95); opacity: 0.8; }
      .btn-prev { background: #16213e; color: #e94560; }
      .btn-next { background: #16213e; color: #53d8fb; }
      .btn-play { background: #0f3460; color: #53d8fb; }
      .btn-stop { background: #e94560; color: #fff; }
      .play-row { display: flex; gap: 12px; width: 100%; max-width: 460px; flex: 1; min-height: 0; }
      .play-row button { flex: 1; min-height: 0; height: auto; }
      .scroll-strip {
        width: 50px; flex-shrink: 0; background: #16213e; border-radius: 14px;
        display: flex; align-items: center; justify-content: center;
        color: #555; font-size: 1.2rem; touch-action: none; cursor: grab;
      }
      .scroll-strip:active { cursor: grabbing; background: #1a2740; }
      .zoom-row { display: flex; gap: 12px; width: 100%; max-width: 460px; }
      .btn-zoom { background: #16213e; color: #aaa; font-size: 1.2rem; min-height: 56px; }
      html { touch-action: manipulation; }
    </style>
    </head>
    <body>
      <div id="status">Connecting...</div>
      <div class="preview-row">
        <div class="preview-card">
          <div class="preview-label">CURRENT</div>
          <div class="preview-image-wrap">
            <img id="currentPreview" class="preview-image" alt="Current slide preview">
            <div id="currentPreviewEmpty" class="preview-empty">No preview</div>
          </div>
        </div>
        <div class="preview-card">
          <div class="preview-label">NEXT</div>
          <div class="preview-image-wrap">
            <img id="nextPreview" class="preview-image" alt="Next slide preview">
            <div id="nextPreviewEmpty" class="preview-empty">No preview</div>
          </div>
        </div>
      </div>
      <div class="nav-row">
        <button class="btn-prev" onclick="send('/prev')">&lsaquo; Prev</button>
        <button class="btn-next" onclick="send('/next')">Next &rsaquo;</button>
      </div>
      <div class="play-row">
        <button id="playBtn" class="btn-play" onclick="togglePlay()">&#9654; Start</button>
        <div class="scroll-strip" id="scrollStrip">&#8597;</div>
      </div>
      <div class="zoom-row">
        <button class="btn-zoom" onclick="send('/zoomout')">A-</button>
        <button class="btn-zoom" onclick="send('/zoomin')">A+</button>
      </div>
      <div id="url"></div>
      <script>
        let presenting = false;

        function send(path) {
          fetch(path).catch(() => {});
        }

        function togglePlay() {
          send(presenting ? '/stop' : '/play');
        }

        function setPreview(imageId, emptyId, available, url) {
          const image = document.getElementById(imageId);
          const empty = document.getElementById(emptyId);
          if (!available || !url) {
            image.style.display = 'none';
            empty.style.display = 'block';
            image.removeAttribute('src');
            return;
          }

          if (image.dataset.lastUrl !== url) {
            image.src = url;
            image.dataset.lastUrl = url;
          }
          image.style.display = 'block';
          empty.style.display = 'none';
        }

        function poll() {
          fetch('/status').then(r => r.json()).then(d => {
            document.getElementById('status').textContent =
              'Slide ' + d.slide + ' / ' + d.total;
            document.getElementById('url').textContent = d.url || '';

            setPreview('currentPreview', 'currentPreviewEmpty', d.currentPreviewAvailable, d.currentPreviewURL);
            setPreview('nextPreview', 'nextPreviewEmpty', d.nextPreviewAvailable, d.nextPreviewURL);

            presenting = d.presenting;
            const btn = document.getElementById('playBtn');
            if (presenting) {
              btn.textContent = '\\u25A0 Stop';
              btn.className = 'btn-stop';
            } else {
              btn.textContent = '\\u25B6 Start';
              btn.className = 'btn-play';
            }
          }).catch(() => {
            document.getElementById('status').textContent = 'Disconnected';
          });
        }

        setInterval(poll, 1000);
        poll();

        const strip = document.getElementById('scrollStrip');
        let lastY = null;
        let pendingDy = 0;
        let sendTimer = null;

        function flushScroll() {
          if (pendingDy !== 0) {
            fetch('/scroll?dy=' + Math.round(pendingDy)).catch(() => {});
            pendingDy = 0;
          }
          sendTimer = null;
        }

        strip.addEventListener('touchstart', e => {
          e.preventDefault();
          lastY = e.touches[0].clientY;
          pendingDy = 0;
        }, {passive: false});

        strip.addEventListener('touchmove', e => {
          e.preventDefault();
          const y = e.touches[0].clientY;
          if (lastY !== null) {
            pendingDy += (y - lastY) * 2;
            lastY = y;
            if (!sendTimer) {
              sendTimer = setTimeout(flushScroll, 50);
            }
          }
        }, {passive: false});

        strip.addEventListener('touchend', () => {
          lastY = null;
          flushScroll();
          if (sendTimer) { clearTimeout(sendTimer); sendTimer = null; }
        });
      </script>
    </body>
    </html>
    """
}
