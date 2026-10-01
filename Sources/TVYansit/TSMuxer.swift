import Foundation

/// H.264 (Annex B) ve AAC (ADTS) verisini MPEG-TS paketlerine sarar.
/// TV'lerin DLNA oynaticilari canli yayini en iyi bu bicimde oynatir.
final class TSMuxer {
    static let packetSize = 188

    private let pmtPID: UInt16 = 0x1000
    private let videoPID: UInt16 = 0x100
    private let audioPID: UInt16 = 0x101
    let hasAudio: Bool
    private var continuity: [UInt16: UInt8] = [:]

    init(hasAudio: Bool) {
        self.hasAudio = hasAudio
    }

    /// Her anahtar karenin onune PAT/PMT eklenir; boylece yayina sonradan
    /// baglanan istemci ilk anahtar karede oynatmaya baslayabilir.
    func video(annexB: Data, pts: UInt64, pcr: UInt64, isKeyframe: Bool) -> Data {
        var out = Data()
        if isKeyframe {
            out.append(pat())
            out.append(pmt())
        }
        out.append(pes(pid: videoPID, streamID: 0xE0, payload: annexB, pts: pts, pcr: pcr, randomAccess: isKeyframe))
        return out
    }

    func audio(adts: Data, pts: UInt64) -> Data {
        pes(pid: audioPID, streamID: 0xC0, payload: adts, pts: pts, pcr: nil, randomAccess: false)
    }

    // MARK: - Tablolar

    private func pat() -> Data {
        var section = Data([0x00])                       // table_id
        let body: [UInt8] = [
            0x00, 0x01,                                  // transport_stream_id
            0xC1, 0x00, 0x00,                            // version, current, section numbers
            0x00, 0x01,                                  // program_number 1
            0xE0 | UInt8(pmtPID >> 8), UInt8(pmtPID & 0xFF),
        ]
        section.append(contentsOf: sectionLength(body.count + 4))
        section.append(contentsOf: body)
        section.append(contentsOf: crc32(section))
        return psiPacket(pid: 0, section: section)
    }

    private func pmt() -> Data {
        var streams: [UInt8] = [
            0x1B, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00,   // H.264
        ]
        if hasAudio {
            streams += [0x0F, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00]  // AAC ADTS
        }
        var section = Data([0x02])
        let body: [UInt8] = [
            0x00, 0x01,                                  // program_number
            0xC1, 0x00, 0x00,
            0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF),   // PCR PID
            0xF0, 0x00,                                  // program_info_length
        ] + streams
        section.append(contentsOf: sectionLength(body.count + 4))
        section.append(contentsOf: body)
        section.append(contentsOf: crc32(section))
        return psiPacket(pid: pmtPID, section: section)
    }

    private func sectionLength(_ length: Int) -> [UInt8] {
        [0xB0 | UInt8((length >> 8) & 0x0F), UInt8(length & 0xFF)]
    }

    private func psiPacket(pid: UInt16, section: Data) -> Data {
        var packet = Data([0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | nextCC(pid), 0x00])
        packet.append(section)
        packet.append(Data(repeating: 0xFF, count: Self.packetSize - packet.count))
        return packet
    }

    // MARK: - PES

    private func pes(pid: UInt16, streamID: UInt8, payload: Data, pts: UInt64, pcr: UInt64?, randomAccess: Bool) -> Data {
        var header = Data([0x00, 0x00, 0x01, streamID])
        let headerData = timestamp(pts, marker: 0x20)
        // Video icin uzunluk 0 (sinirsiz) olabilir; ses icin sigmazsa yine 0 yazilir
        let fullLength = 3 + headerData.count + payload.count
        let pesLength = (streamID == 0xE0 || fullLength > 0xFFFF) ? 0 : fullLength
        header.append(contentsOf: [UInt8(pesLength >> 8), UInt8(pesLength & 0xFF)])
        header.append(contentsOf: [0x80, 0x80, UInt8(headerData.count)])   // PTS var
        header.append(headerData)

        let stream = header + payload
        var out = Data()
        out.reserveCapacity((stream.count / 184 + 2) * Self.packetSize)
        var offset = 0
        var first = true

        while offset < stream.count {
            var adaptation = Data()
            if first, let pcr {
                // PCR + rastgele erisim bayragi
                let base = pcr & 0x1_FFFF_FFFF
                adaptation = Data([
                    0x00, // uzunluk sonra yazilir
                    (randomAccess ? 0x40 : 0x00) | 0x10,
                    UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF),
                    UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF),
                    UInt8((base & 1) << 7) | 0x7E, 0x00,
                ])
            }

            let remaining = stream.count - offset
            var space = 184 - adaptation.count
            if remaining < space {
                // Son paket: kalan alani adaptation alaninda dolguyla kapat
                let stuffing = space - remaining
                if adaptation.isEmpty {
                    if stuffing == 1 {
                        adaptation = Data([0x00])
                    } else {
                        adaptation = Data([0x00, 0x00]) + Data(repeating: 0xFF, count: stuffing - 2)
                    }
                } else {
                    adaptation.append(Data(repeating: 0xFF, count: stuffing))
                }
                space = remaining
            }
            if !adaptation.isEmpty {
                adaptation[adaptation.startIndex] = UInt8(adaptation.count - 1)
            }

            let control: UInt8 = adaptation.isEmpty ? 0x10 : 0x30
            var packet = Data([
                0x47,
                (first ? 0x40 : 0x00) | UInt8(pid >> 8),
                UInt8(pid & 0xFF),
                control | nextCC(pid),
            ])
            packet.append(adaptation)
            packet.append(stream[stream.startIndex + offset ..< stream.startIndex + offset + space])
            out.append(packet)
            offset += space
            first = false
        }
        return out
    }

    private func timestamp(_ value: UInt64, marker: UInt8) -> Data {
        let ts = value & 0x1_FFFF_FFFF
        return Data([
            marker | UInt8((ts >> 29) & 0x0E) | 0x01,
            UInt8((ts >> 22) & 0xFF),
            UInt8((ts >> 14) & 0xFE) | 0x01,
            UInt8((ts >> 7) & 0xFF),
            UInt8((ts << 1) & 0xFE) | 0x01,
        ])
    }

    private func nextCC(_ pid: UInt16) -> UInt8 {
        let value = continuity[pid, default: 0]
        continuity[pid] = (value + 1) & 0x0F
        return value
    }

    // MARK: - CRC32 (MPEG-2)

    private static let crcTable: [UInt32] = (0 ..< 256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0 ..< 8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    private func crc32(_ data: Data) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc << 8) ^ Self.crcTable[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}
