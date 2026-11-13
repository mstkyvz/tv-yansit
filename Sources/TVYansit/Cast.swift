import Foundation
import Network

/// Agdaki Google Cast (Chromecast / Android TV / Google TV) cihazi.
struct CastDevice: Hashable {
    let id: String
    let name: String
    let model: String
    let endpoint: NWEndpoint
}

enum CastError: LocalizedError {
    case connection(String)
    case timeout(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .connection(let detail): return "TV'ye bağlanılamadı: \(detail)"
        case .timeout(let step): return "TV yanıt vermedi (\(step))."
        case .rejected(let detail): return "TV yayını reddetti: \(detail)"
        }
    }
}

// MARK: - Kesif (mDNS)

enum CastDiscovery {
    static func discover(timeout: TimeInterval = 3) async -> [CastDevice] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "tvyansit.cast.browse")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: NWParameters())
            var found: [String: CastDevice] = [:]
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .service(let serviceName, _, _, _) = result.endpoint else { continue }
                    var txt: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                    let id = txt["id"] ?? serviceName
                    found[id] = CastDevice(id: id, name: txt["fn"] ?? serviceName, model: txt["md"] ?? "",
                                           endpoint: result.endpoint)
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                continuation.resume(returning: Array(found.values))
            }
        }
    }
}

// MARK: - Oturum (CASTV2)

/// TV ile TLS uzerinden CASTV2 oturumu. Default Media Receiver'i acar,
/// HLS adresini oynatir ve TV'nin sesini kontrol eder.
final class CastSession: @unchecked Sendable {
    private static let defaultMediaReceiver = "CC1AD845"
    private static let connectionNS = "urn:x-cast:com.google.cast.tp.connection"
    private static let heartbeatNS = "urn:x-cast:com.google.cast.tp.heartbeat"
    private static let receiverNS = "urn:x-cast:com.google.cast.receiver"
    private static let mediaNS = "urn:x-cast:com.google.cast.media"

    private typealias Matcher = (_ namespace: String, _ payload: [String: Any]) -> Result<[String: Any], Error>?

    private final class Waiter {
        let match: Matcher
        let continuation: CheckedContinuation<[String: Any], Error>
        init(match: @escaping Matcher, continuation: CheckedContinuation<[String: Any], Error>) {
            self.match = match
            self.continuation = continuation
        }
    }

    private let queue = DispatchQueue(label: "tvyansit.cast")
    private let connection: NWConnection
    private let sourceID = "sender-tvyansit"
    private var buffer = Data()
    private var waiters: [UUID: Waiter] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var lastRequestID = 0
    private var transportID: String?
    private var sessionID: String?
    private var volume: (level: Double, muted: Bool)?
    private var closed = false

    var isOpen: Bool { queue.sync { !closed } }

    private init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Cast cihazlari kendinden imzali sertifika kullanir
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
    }

    static func open(_ device: CastDevice) async throws -> CastSession {
        let session = CastSession(endpoint: device.endpoint)
        try await session.connect()
        return session
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            func finish(_ error: Error?) {
                guard !resumed else { return }
                resumed = true
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(nil)
                case .waiting(let error):
                    finish(CastError.connection(error.localizedDescription))
                    self?.connection.cancel()
                case .failed(let error):
                    finish(CastError.connection(error.localizedDescription))
                    self?.handleClosed()
                case .cancelled:
                    finish(CastError.connection("bağlantı kapandı"))
                    self?.handleClosed()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard !resumed else { return }
                finish(CastError.timeout("bağlantı"))
                self?.connection.cancel()
            }
        }
        queue.async {
            self.send(Self.connectionNS, ["type": "CONNECT"])
            self.startHeartbeat()
            self.receive()
        }
    }

    // MARK: Oynatma

    /// Default Media Receiver'i acar ve canli HLS adresini oynatir.
    func play(url: String, title: String) async throws {
        let launchID = nextRequestID()
        let app = try await request(Self.receiverNS, ["type": "LAUNCH", "appId": Self.defaultMediaReceiver, "requestId": launchID],
                                    step: "uygulama açma", timeout: 30) { namespace, payload in
            guard namespace == Self.receiverNS else { return nil }
            let type = payload["type"] as? String
            if type == "LAUNCH_ERROR" || (type == "LAUNCH_STATUS" && (payload["status"] as? String) == "USER_DENIED") {
                return .failure(CastError.rejected(payload["reason"] as? String ?? "izin verilmedi"))
            }
            if type == "RECEIVER_STATUS", let app = Self.mediaApp(in: payload) { return .success(app) }
            return nil
        }
        guard let transport = app["transportId"] as? String else { throw CastError.rejected("uygulama açılamadı") }
        queue.sync {
            transportID = transport
            sessionID = app["sessionId"] as? String
            send(Self.connectionNS, ["type": "CONNECT"], to: transport)
        }

        let loadID = nextRequestID()
        var acknowledged = false
        let load: [String: Any] = [
            "type": "LOAD",
            "requestId": loadID,
            "autoplay": true,
            "media": [
                "contentId": url,
                "contentUrl": url,
                "contentType": "application/x-mpegURL",
                "streamType": "LIVE",
                "hlsSegmentFormat": "ts",
                "hlsVideoSegmentFormat": "mpeg2_ts",
                "metadata": ["metadataType": 0, "title": title],
            ] as [String: Any],
        ]
        _ = try await request(Self.mediaNS, load, to: transport, step: "yayını oynatma", timeout: 25) { namespace, payload in
            guard namespace == Self.mediaNS else { return nil }
            let type = payload["type"] as? String ?? ""
            let requestID = payload["requestId"] as? Int
            if ["LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "ERROR"].contains(type), requestID == loadID {
                return .failure(CastError.rejected(type))
            }
            guard type == "MEDIA_STATUS", let status = (payload["status"] as? [[String: Any]])?.first else { return nil }
            if requestID == loadID { acknowledged = true }
            guard acknowledged else { return nil }
            switch status["playerState"] as? String {
            case "PLAYING", "BUFFERING", "PAUSED":
                return .success(status)
            case "IDLE" where status["idleReason"] as? String == "ERROR":
                return .failure(CastError.rejected("TV akışı açamadı"))
            default:
                return nil
            }
        }
    }

    /// Uygulamayi kapatir (TV ana ekrana doner) ve baglantiyi keser.
    func stop() async {
        let session: String? = queue.sync { sessionID }
        if let session {
            let id = nextRequestID()
            _ = try? await request(Self.receiverNS, ["type": "STOP", "requestId": id, "sessionId": session],
                                   step: "durdurma", timeout: 3) { namespace, payload in
                namespace == Self.receiverNS && payload["type"] as? String == "RECEIVER_STATUS" ? .success(payload) : nil
            }
        }
        close()
    }

    func close() {
        queue.async {
            if let transport = self.transportID {
                self.send(Self.connectionNS, ["type": "CLOSE"], to: transport)
            }
            self.send(Self.connectionNS, ["type": "CLOSE"])
            self.connection.cancel()
            self.handleClosed()
        }
    }

    // MARK: Ses

    /// TV'nin ses duzeyi (0...1) ve sessiz durumu.
    func currentVolume() async -> (level: Double, muted: Bool)? {
        let id = nextRequestID()
        _ = try? await request(Self.receiverNS, ["type": "GET_STATUS", "requestId": id], step: "durum", timeout: 3) { namespace, payload in
            namespace == Self.receiverNS && payload["type"] as? String == "RECEIVER_STATUS" ? .success(payload) : nil
        }
        return queue.sync { volume }
    }

    func setVolume(_ level: Double) {
        let id = nextRequestID()
        queue.async {
            self.send(Self.receiverNS, ["type": "SET_VOLUME", "requestId": id, "volume": ["level": max(0, min(1, level))]])
        }
    }

    func setMuted(_ muted: Bool) {
        let id = nextRequestID()
        queue.async {
            self.send(Self.receiverNS, ["type": "SET_VOLUME", "requestId": id, "volume": ["muted": muted]])
        }
    }

    // MARK: - Mesajlasma

    private func nextRequestID() -> Int {
        queue.sync {
            lastRequestID += 1
            return lastRequestID
        }
    }

    private func request(_ namespace: String, _ payload: [String: Any], to destination: String = "receiver-0",
                         step: String, timeout: TimeInterval, match: @escaping Matcher) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: CastError.connection("bağlantı kapalı"))
                    return
                }
                let id = UUID()
                self.waiters[id] = Waiter(match: match, continuation: continuation)
                self.send(namespace, payload, to: destination)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.waiters.removeValue(forKey: id)?.continuation.resume(throwing: CastError.timeout(step))
                }
            }
        }
    }

    private func send(_ namespace: String, _ payload: [String: Any], to destination: String = "receiver-0") {
        guard !closed, let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        var message = Data()
        message.append(CastProto.varintField(1, 0))              // protocol_version: CASTV2_1_0
        message.append(CastProto.stringField(2, sourceID))
        message.append(CastProto.stringField(3, destination))
        message.append(CastProto.stringField(4, namespace))
        message.append(CastProto.varintField(5, 0))              // payload_type: STRING
        message.append(CastProto.stringField(6, text))
        var frame = Data()
        let length = UInt32(message.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(message)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                self.handleClosed()
                return
            }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            let fields = CastProto.decode(body)
            guard let namespace = fields[4], let text = fields[6],
                  let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { continue }
            handle(namespace: namespace, source: fields[2] ?? "receiver-0", payload: payload)
        }
    }

    private func handle(namespace: String, source: String, payload: [String: Any]) {
        let type = payload["type"] as? String
        if namespace == Self.heartbeatNS {
            if type == "PING" { send(Self.heartbeatNS, ["type": "PONG"], to: source) }
            return
        }
        if namespace == Self.connectionNS, type == "CLOSE" {
            if source == transportID { transportID = nil } else {
                connection.cancel()
                handleClosed()
            }
            return
        }
        if namespace == Self.receiverNS, type == "RECEIVER_STATUS",
           let status = payload["status"] as? [String: Any] {
            if let vol = status["volume"] as? [String: Any] {
                volume = ((vol["level"] as? Double) ?? volume?.level ?? 0, (vol["muted"] as? Bool) ?? false)
            }
            if Self.mediaApp(in: payload) == nil, transportID != nil {
                // Uygulama TV tarafinda kapatildi
                transportID = nil
                sessionID = nil
            }
        }
        for (id, waiter) in waiters {
            guard let result = waiter.match(namespace, payload) else { continue }
            waiters.removeValue(forKey: id)
            switch result {
            case .success(let value): waiter.continuation.resume(returning: value)
            case .failure(let error): waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.send(Self.heartbeatNS, ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
    }

    /// Kuyrukta cagrilir.
    private func handleClosed() {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: CastError.connection("bağlantı koptu")) }
    }

    private static func mediaApp(in payload: [String: Any]) -> [String: Any]? {
        let apps = (payload["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
        return apps.first { $0["appId"] as? String == defaultMediaReceiver }
    }
}

// MARK: - Protobuf (CastMessage)

/// CastMessage icin yeterli kucuk protobuf kodlayici/cozucu.
private enum CastProto {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func varintField(_ number: UInt64, _ value: UInt64) -> Data {
        varint(number << 3) + varint(value)
    }

    static func stringField(_ number: UInt64, _ value: String) -> Data {
        let bytes = Data(value.utf8)
        return varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }

    /// Yalnizca metin (length-delimited) alanlarini dondurur.
    static func decode(_ data: Data) -> [Int: String] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Int: String] = [:]
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = readVarint() else { break }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard readVarint() != nil else { return fields }
            case 2:
                guard let length = readVarint(), index + Int(length) <= bytes.count else { return fields }
                fields[number] = String(decoding: bytes[index ..< index + Int(length)], as: UTF8.self)
                index += Int(length)
            case 1:
                index += 8
            case 5:
                index += 4
            default:
                return fields
            }
        }
        return fields
    }
}
