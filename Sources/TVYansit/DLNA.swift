import Darwin
import Foundation

/// Agdaki DLNA/UPnP oynaticisi (TV).
struct DLNADevice: Identifiable, Hashable {
    let id: String              // UDN
    let name: String
    let model: String
    let host: String
    let avTransportURL: URL
    let renderingControlURL: URL?
}

enum DLNAError: LocalizedError {
    case soapFault(String)
    var errorDescription: String? {
        switch self {
        case .soapFault(let message): return "TV komutu reddetti: \(message)"
        }
    }
}

enum DLNA {
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"

    // MARK: - Kesif (SSDP)

    /// Agdaki oynaticilari bulur. `localIP` verilirse cok noktaya yayin o arayuzden gider.
    static func discover(localIP: String?, timeout: TimeInterval = 3) async -> [DLNADevice] {
        let locations = await Task.detached { ssdpSearch(localIP: localIP, timeout: timeout) }.value
        var devices: [DLNADevice] = []
        await withTaskGroup(of: DLNADevice?.self) { group in
            for location in locations {
                group.addTask { await describe(location) }
            }
            for await device in group {
                if let device, !devices.contains(where: { $0.id == device.id }) {
                    devices.append(device)
                }
            }
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func ssdpSearch(localIP: String?, timeout: TimeInterval) -> Set<URL> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        if let localIP {
            var interface = in_addr()
            inet_pton(AF_INET, localIP, &interface)
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
        }
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)

        let searchTargets = [
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            avTransport,
        ]
        func send() {
            for st in searchTargets {
                let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
                _ = message.withCString { pointer in
                    withUnsafePointer(to: &target) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var locations = Set<URL>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        send()
        var resent = false
        while Date() < deadline {
            // UDP kaybolabilir: yarida bir kez daha sor
            if !resent, Date() > deadline.addingTimeInterval(-timeout / 2) {
                send()
                resent = true
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            let response = String(decoding: buffer[0 ..< count], as: UTF8.self)
            for line in response.components(separatedBy: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location",
                   let url = URL(string: parts[1].trimmingCharacters(in: .whitespaces)) {
                    locations.insert(url)
                }
            }
        }
        return locations
    }

    private static func describe(_ location: URL) async -> DLNADevice? {
        var request = URLRequest(url: location, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let parser = DescriptionParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }

        let base = parser.urlBase.flatMap(URL.init(string:)) ?? location
        func resolve(_ path: String?) -> URL? {
            guard let path else { return nil }
            return URL(string: path, relativeTo: base)?.absoluteURL
        }
        guard let transport = resolve(parser.controlURLs[avTransport]) else { return nil }
        return DLNADevice(
            id: parser.udn ?? location.absoluteString,
            name: parser.friendlyName ?? location.host ?? "TV",
            model: [parser.manufacturer, parser.modelName].compactMap { $0 }.joined(separator: " "),
            host: location.host ?? "",
            avTransportURL: transport,
            renderingControlURL: resolve(parser.controlURLs[renderingControl])
        )
    }

    // MARK: - Kontrol (SOAP)

    static func play(_ device: DLNADevice, streamURL: String, title: String) async throws {
        let protocolInfo = "http-get:*:video/mpeg:\(HTTPServer.dlnaContentFeatures)"
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="tvyansit" parentID="0" restricted="1">\
        <dc:title>\(escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class>\
        <res protocolInfo="\(protocolInfo)">\(escape(streamURL))</res></item></DIDL-Lite>
        """
        // Onceki yayin aciksa once durdur; hata olursa onemli degil
        _ = try? await soap(device.avTransportURL, avTransport, "Stop", [("InstanceID", "0")])
        _ = try await soap(device.avTransportURL, avTransport, "SetAVTransportURI", [
            ("InstanceID", "0"), ("CurrentURI", streamURL), ("CurrentURIMetaData", didl),
        ])
        _ = try await soap(device.avTransportURL, avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    static func stop(_ device: DLNADevice) async {
        _ = try? await soap(device.avTransportURL, avTransport, "Stop", [("InstanceID", "0")])
    }

    static func volume(_ device: DLNADevice) async -> Int? {
        guard let url = device.renderingControlURL,
              let xml = try? await soap(url, renderingControl, "GetVolume", [("InstanceID", "0"), ("Channel", "Master")])
        else { return nil }
        return value(of: "CurrentVolume", in: xml).flatMap(Int.init)
    }

    static func setVolume(_ device: DLNADevice, _ volume: Int) async throws {
        guard let url = device.renderingControlURL else { return }
        _ = try await soap(url, renderingControl, "SetVolume", [
            ("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(max(0, min(100, volume)))),
        ])
    }

    static func isMuted(_ device: DLNADevice) async -> Bool? {
        guard let url = device.renderingControlURL,
              let xml = try? await soap(url, renderingControl, "GetMute", [("InstanceID", "0"), ("Channel", "Master")])
        else { return nil }
        return value(of: "CurrentMute", in: xml).map { $0 == "1" || $0.lowercased() == "true" }
    }

    static func setMuted(_ device: DLNADevice, _ muted: Bool) async throws {
        guard let url = device.renderingControlURL else { return }
        _ = try await soap(url, renderingControl, "SetMute", [
            ("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0"),
        ])
    }

    private static func soap(_ url: URL, _ service: String, _ action: String, _ arguments: [(String, String)]) async throws -> String {
        let args = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let detail = value(of: "errorDescription", in: text) ?? value(of: "faultstring", in: text) ?? "HTTP \(http.statusCode)"
            throw DLNAError.soapFault("\(action): \(detail)")
        }
        return text
    }

    private static func value(of tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound ..< xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound ..< end.lowerBound])
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// UPnP cihaz tanim XML'inden gereken alanlari toplar.
private final class DescriptionParser: NSObject, XMLParserDelegate {
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var udn: String?
    var urlBase: String?
    var controlURLs: [String: String] = [:]

    private var text = ""
    private var serviceType: String?
    private var controlURL: String?
    private var depth = 0
    private var deviceDepth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        depth += 1
        text = ""
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "device", deviceDepth == 0 { deviceDepth = depth }
        if local == "service" { serviceType = nil; controlURL = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ust cihazin bilgileri (ic ice cihazlarda ilk olan)
        let topLevel = depth == deviceDepth + 1
        switch local {
        case "friendlyName" where topLevel && friendlyName == nil: friendlyName = value
        case "manufacturer" where topLevel && manufacturer == nil: manufacturer = value
        case "modelName" where topLevel && modelName == nil: modelName = value
        case "UDN" where topLevel && udn == nil: udn = value
        case "URLBase": urlBase = value
        case "serviceType": serviceType = value
        case "controlURL": controlURL = value
        case "service":
            if let serviceType, let controlURL, controlURLs[serviceType] == nil {
                // "...:AVTransport:2" gibi surumleri de :1 olarak kabul et
                let key = serviceType.replacingOccurrences(of: #":\d+$"#, with: ":1", options: .regularExpression)
                controlURLs[key] = controlURL
            }
        default:
            break
        }
        text = ""
        depth -= 1
    }
}
