import Foundation
import Network

/// Eski TV tarayicilari icin kucuk HTTP sunucusu.
///  /         MJPEG akisini tam ekran gosteren sayfa
///  /akis     multipart/x-mixed-replace MJPEG akisi
///  /yedek    MJPEG desteklemeyen tarayicilar icin tek tek resim yenileyen sayfa
///  /kare.jpg son kare
///  /canli.ts TV oynaticisi (DLNA) icin H.264 + AAC MPEG-TS akisi
final class HTTPServer {
    private let store: FrameStore
    let broadcaster = TSBroadcaster()
    private let queue = DispatchQueue(label: "tvyansit.http")
    private let boundary = "tvyansitkare"
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]

    /// Akis izleyen istemci sayisi degisince ana kuyrukta cagrilir.
    var onClientCountChange: ((Int) -> Void)?

    init(store: FrameStore) {
        self.store = store
    }

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "TVYansit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gecersiz port: \(port)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        broadcaster.disconnectAll()
        queue.async {
            self.streams.values.forEach { $0.cancel() }
            self.streams.removeAll()
            self.notifyCount()
        }
    }

    // MARK: - Baglantilar

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            let (method, path) = Self.requestLine(data)
            switch path {
            case "/canli.ts":
                self.startTransportStream(connection, headOnly: method == "HEAD")
            case "/akis":
                self.startStream(connection)
            case "/kare.jpg":
                if let frame = self.store.latest {
                    self.respond(connection, status: "200 OK", type: "image/jpeg", body: frame)
                } else {
                    self.respond(connection, status: "503 Service Unavailable", type: "text/plain", body: Data("Henuz kare yok".utf8))
                }
            case "/yedek":
                self.respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Pages.fallback.utf8))
            case "/favicon.ico":
                self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
            default:
                self.respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Pages.main.utf8))
            }
        }
    }

    /// "GET /akis?t=123 HTTP/1.1" -> ("GET", "/akis")
    private static func requestLine(_ data: Data) -> (String, String) {
        let text = String(decoding: data.prefix(2048), as: UTF8.self)
        guard let line = text.split(separator: "\r\n", maxSplits: 1).first else { return ("GET", "/") }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return ("GET", "/") }
        let target = parts[1]
        return (String(parts[0]), String(target.split(separator: "?", maxSplits: 1).first ?? "/"))
    }

    // MARK: - MPEG-TS akisi (DLNA)

    static let dlnaContentFeatures = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    private func startTransportStream(_ connection: NWConnection, headOnly: Bool) {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: video/mpeg\r\n"
            + "transferMode.dlna.org: Streaming\r\n"
            + "contentFeatures.dlna.org: \(Self.dlnaContentFeatures)\r\n"
            + "Cache-Control: no-cache, no-store\r\n"
            + "Connection: close\r\n\r\n"
        if headOnly {
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
        } else {
            broadcaster.add(connection, head: Data(head.utf8))
        }
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - MJPEG akisi

    private func startStream(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        streams[id] = connection
        notifyCount()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.queue.async {
                    if self.streams.removeValue(forKey: id) != nil { self.notifyCount() }
                }
            default:
                break
            }
        }

        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Connection: close\r\n\r\n"
            + "--\(boundary)\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.cancel(); return }
            self?.pump(connection, after: 0)
        })
    }

    /// Bir kare gonderilip bitince sonrakini ister. Yavas istemciler araya giren
    /// kareleri atlar, boylece gecikme birikmez.
    private func pump(_ connection: NWConnection, after seq: UInt64) {
        store.next(after: seq, keepAlive: 2) { [weak self] jpeg, current in
            guard let self, case .ready = connection.state else { return }
            // Sinir satiri karenin hemen arkasina eklenir; tarayici kareyi bir sonraki
            // kareyi beklemeden gosterir.
            var part = Data("Content-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            part.append(jpeg)
            part.append(Data("\r\n--\(self.boundary)\r\n".utf8))
            connection.send(content: part, completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.pump(connection, after: current)
            })
        }
    }

    private func notifyCount() {
        let count = streams.count
        DispatchQueue.main.async { self.onClientCountChange?(count) }
    }
}

/// TV tarayicilari eski oldugu icin sayfalar yalnizca ES5 kullanir.
enum Pages {
    static let main = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>TV Yansit</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
    img{width:100%;height:100%;object-fit:contain;display:block}
    #not{position:fixed;left:0;right:0;bottom:12px;text-align:center;color:#888;font:16px sans-serif}
    #not a{color:#aaa}
    </style></head>
    <body><img id="ekran" src="/akis" alt="">
    <div id="not">Baglaniyor... Goruntu gelmezse <a href="/yedek">yedek moda</a> gec.</div>
    <script>
    var img = document.getElementById('ekran');
    var not = document.getElementById('not');
    img.onload = function () { not.style.display = 'none'; };
    img.onerror = function () {
      not.style.display = 'block';
      setTimeout(function () { img.src = '/akis?t=' + new Date().getTime(); }, 1000);
    };
    </script>
    </body></html>
    """

    static let fallback = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>TV Yansit (yedek)</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
    img{width:100%;height:100%;object-fit:contain;display:block}
    </style></head>
    <body><img id="ekran" alt="">
    <script>
    var img = document.getElementById('ekran');
    function yukle() { img.src = '/kare.jpg?t=' + new Date().getTime(); }
    img.onload = function () { setTimeout(yukle, 30); };
    img.onerror = function () { setTimeout(yukle, 1000); };
    yukle();
    </script>
    </body></html>
    """
}
