import Foundation

/// MPEG-TS akisini anahtar karelerden bolerek canli HLS parcalarina ayirir.
/// Chromecast (Google Cast) oynaticisi ham TS akisini degil HLS'i oynatir.
/// Tum cagrilar TSBroadcaster kuyrugundan yapilir.
final class HLSSegmenter {
    private struct Segment {
        let sequence: Int
        let data: Data
        let duration: Double
        let discontinuity: Bool
        /// Bu parca dahil gorulen toplam kesinti sayisi
        let discontinuityIndex: Int
    }

    /// Bellekte tutulan ve oynatma listesinde gosterilen parca sayisi
    private let kept: Int
    private let listed: Int
    private let minimumDuration: Double
    private let holdBack: Double

    /// Chromecast stres testlerinde secilen degerler:
    ///  - 0,5 sn'lik parcalar + HOLD-BACK 1 sn: oynatici canli uca yakin durur (~2-3 sn gecikme).
    ///  - 40 parcalik (20 sn) pencere: pencere kisa olunca (4-6 parca) kucuk bir takilmada
    ///    oynatma noktasi pencereden duser ve oynatici surekli ileri atlayip tamponluyordu.
    ///    Genis pencere gecikmeyi artirmaz, ag kesintisinden sonra toparlanmayi saglar.
    /// TVY_HLS_SEG / TVY_HLS_LIST / TVY_HLS_HOLDBACK ortam degiskenleriyle denenebilir.
    static let defaultSegmentDuration = 0.5

    init(segmentDuration: Double = Double(ProcessInfo.processInfo.environment["TVY_HLS_SEG"] ?? "") ?? defaultSegmentDuration,
         listed: Int = Int(ProcessInfo.processInfo.environment["TVY_HLS_LIST"] ?? "") ?? 40) {
        minimumDuration = segmentDuration * 0.9
        holdBack = Double(ProcessInfo.processInfo.environment["TVY_HLS_HOLDBACK"] ?? "") ?? 1.0
        self.listed = listed
        kept = listed + 4
    }

    private var segments: [Segment] = []
    private var current = Data()
    private var currentStart: UInt64?
    private var currentDiscontinuity = false
    private var nextSequence = 0
    private var discontinuityCount = 0
    private var pendingDiscontinuity = false

    /// Yeni anahtar kare geldi ama ses kodlayicidan gecikmeli ciktigi icin onceki
    /// parcanin zaman araligina ait ses kareleri henuz gelmedi. Parca, bu sesler
    /// gelene kadar (en fazla `audioWait`) acik tutulur. Aksi halde her parcanin
    /// sonunda ses deligi olusur ve Chromecast oynaticisi takilip ileri atlar.
    private var closing: (data: Data, start: UInt64, end: UInt64, discontinuity: Bool)?
    private let audioWait: UInt64 = 27_000   // 300 ms (90 kHz)

    var readyCount: Int { segments.count }

    func appendVideo(_ packets: Data, pts: UInt64, isKeyframe: Bool, hasAudio: Bool) {
        if let closing, !hasAudio || pts &- closing.end > audioWait || pts < closing.end {
            finishClosing()
        }
        if isKeyframe {
            if let start = currentStart {
                let duration = Double(pts &- start) / 90_000
                if pts < start {
                    // Zaman damgalari geri gitti: bekletmeden kapat
                    finishClosing()
                    closing = (current, start, start + 90_000, currentDiscontinuity)
                    finishClosing()
                    begin(at: pts)
                } else if duration >= minimumDuration {
                    finishClosing()
                    closing = (current, start, pts, currentDiscontinuity)
                    if !hasAudio { finishClosing() }
                    begin(at: pts)
                }
            } else {
                begin(at: pts)
            }
        }
        guard currentStart != nil else { return }   // ilk anahtar kareye kadar atla
        current.append(packets)
    }

    func appendAudio(_ packets: Data, pts: UInt64) {
        if let closing {
            if pts < closing.end {
                self.closing?.data.append(packets)
                return
            }
            finishClosing()
        }
        guard currentStart != nil else { return }
        current.append(packets)
    }

    /// Kodlayici bastan kuruldu (zaman damgalari sifirlandi).
    func discontinuity() {
        finishClosing()
        current = Data()
        currentStart = nil
        pendingDiscontinuity = !segments.isEmpty
    }

    func reset() {
        segments.removeAll()
        closing = nil
        current = Data()
        currentStart = nil
        pendingDiscontinuity = false
    }

    func segment(_ sequence: Int) -> Data? {
        segments.first { $0.sequence == sequence }?.data
    }

    func playlist() -> String? {
        let visible = segments.suffix(listed)
        guard let first = visible.first else { return nil }
        // Standart: EXTINF en yakin tama yuvarlaninca hedefi asmamali. Yukari yuvarlamak
        // (1,02 sn -> 2) oynaticinin canli ucun 3 x hedef gerisinde, yani 6 sn geride durmasina yol aciyordu.
        let target = Int((visible.map(\.duration).max() ?? 1).rounded())
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(max(1, target))",
            "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.discontinuityIndex - (first.discontinuity ? 1 : 0))",
        ]
        if holdBack > 0 {
            // Oynaticiya canli ucun ne kadar gerisinden oynatacagini soyler (varsayilan 3 x hedef)
            lines.append(String(format: "#EXT-X-SERVER-CONTROL:HOLD-BACK=%.1f", holdBack))
        }
        for (index, segment) in visible.enumerated() {
            if segment.discontinuity, index > 0 { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("hls/\(segment.sequence).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func begin(at pts: UInt64) {
        current = Data()
        currentStart = pts
        currentDiscontinuity = pendingDiscontinuity
        pendingDiscontinuity = false
    }

    private func finishClosing() {
        guard let closing else { return }
        self.closing = nil
        guard !closing.data.isEmpty else { return }
        if closing.discontinuity { discontinuityCount += 1 }
        segments.append(Segment(sequence: nextSequence, data: closing.data,
                                duration: Double(closing.end - closing.start) / 90_000,
                                discontinuity: closing.discontinuity, discontinuityIndex: discontinuityCount))
        nextSequence += 1
        if segments.count > kept { segments.removeFirst(segments.count - kept) }
    }
}
