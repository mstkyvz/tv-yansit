import CoreMedia
import Foundation
import Network

/// Kodlanmis video/sesi MPEG-TS'e cevirir ve /canli.ts'e bagli istemcilere dagitir.
final class TSBroadcaster {
    private final class Client {
        let connection: NWConnection
        var waitingForKeyframe = true
        var pendingBytes = 0
        init(connection: NWConnection) { self.connection = connection }
    }

    /// Bir istemcinin gonderilmeyi bekleyen verisi bu siniri asarsa bir sonraki
    /// anahtar kareye kadar veri atlanir (TV yetisemiyorsa gecikme birikmesin).
    private let maxBacklog = 6 * 1024 * 1024
    private let queue = DispatchQueue(label: "tvyansit.ts")
    private var muxer = TSMuxer(hasAudio: true)
    private var clients: [ObjectIdentifier: Client] = [:]
    private var baseTime: CMTime?

    var onClientCountChange: ((Int) -> Void)?

    /// Kaynak veya ayar degisince akis kesilmeden devam eder (zaman damgalari ayni
    /// saatten gelir). Yalnizca ses acilip kapaninca akis bastan kurulur.
    func prepare(hasAudio: Bool) {
        queue.async {
            if self.muxer.hasAudio != hasAudio {
                self.muxer = TSMuxer(hasAudio: hasAudio)
                self.baseTime = nil
            }
            self.clients.values.forEach { $0.waitingForKeyframe = true }
        }
    }

    // MARK: - Giris

    func video(_ annexB: Data, pts: CMTime, isKeyframe: Bool) {
        queue.async {
            guard let pts90 = self.ticks(pts) else { return }
            // PCR, PTS'ten 300 ms once: oynaticiya cozme payi birakir
            let packets = self.muxer.video(annexB: annexB, pts: pts90, pcr: pts90 - 27_000, isKeyframe: isKeyframe)
            self.broadcast(packets, isKeyframe: isKeyframe)
        }
    }

    func audio(_ adts: Data, pts: CMTime) {
        queue.async {
            guard self.baseTime != nil, let pts90 = self.ticks(pts) else { return }
            self.broadcast(self.muxer.audio(adts: adts, pts: pts90), isKeyframe: false)
        }
    }

    /// 90 kHz saat; ilk video karesi 1 sn'ye denk gelir (PCR negatif olmasin)
    private func ticks(_ time: CMTime) -> UInt64? {
        guard time.isValid else { return nil }
        if baseTime == nil { baseTime = time }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(time, baseTime!)) + 1
        guard seconds > 0 else { return nil }
        return UInt64(seconds * 90_000)
    }

    // MARK: - Istemciler

    func add(_ connection: NWConnection, head: Data) {
        queue.async {
            let client = Client(connection: connection)
            let id = ObjectIdentifier(connection)
            self.clients[id] = client
            self.notifyCount()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.queue.async {
                        if self?.clients.removeValue(forKey: id) != nil { self?.notifyCount() }
                    }
                default:
                    break
                }
            }
            connection.send(content: head, completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
    }

    func disconnectAll() {
        queue.async {
            self.clients.values.forEach { $0.connection.cancel() }
            self.clients.removeAll()
            self.muxer = TSMuxer(hasAudio: self.muxer.hasAudio)
            self.baseTime = nil
            self.notifyCount()
        }
    }

    private func broadcast(_ data: Data, isKeyframe: Bool) {
        for client in clients.values {
            if client.waitingForKeyframe {
                guard isKeyframe else { continue }
                client.waitingForKeyframe = false
            }
            if client.pendingBytes > maxBacklog {
                client.waitingForKeyframe = true
                continue
            }
            client.pendingBytes += data.count
            let size = data.count
            client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    client.connection.cancel()
                    return
                }
                self.queue.async { client.pendingBytes -= size }
            })
        }
    }

    private func notifyCount() {
        let count = clients.count
        DispatchQueue.main.async { self.onClientCountChange?(count) }
    }
}
