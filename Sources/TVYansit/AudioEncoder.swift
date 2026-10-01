import AVFoundation
import CoreMedia
import Foundation

/// ScreenCaptureKit'ten gelen sistem sesini AAC-LC'ye kodlar ve ADTS cerceveleri uretir.
final class AudioEncoder {
    typealias Output = (_ adts: Data, _ pts: CMTime) -> Void

    static let sampleRate = 48_000
    static let channels = 2

    private let output: Output
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat
    private let bitrate: Int

    /// Kodlayiciya verilmeyi bekleyen PCM tamponlari
    private var pending: [AVAudioPCMBuffer] = []
    /// Ilk ornegin zamani; sonraki AAC cercevelerinin zamani ornek sayisindan hesaplanir
    private var basePTS: CMTime?
    private var encodedFrames: Int64 = 0

    init(bitrate: Int = 160_000, output: @escaping Output) {
        self.output = output
        self.bitrate = bitrate
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(Self.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        outputFormat = AVAudioFormat(streamDescription: &description)!
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if converter == nil || inputFormat != pcm.format {
            inputFormat = pcm.format
            converter = AVAudioConverter(from: pcm.format, to: outputFormat)
            converter?.bitRate = bitrate
        }
        if basePTS == nil {
            basePTS = sampleBuffer.presentationTimeStamp
        }
        pending.append(pcm)
        drain()
    }

    private func drain() {
        guard let converter else { return }
        while true {
            let packet = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: packet, error: &error) { [weak self] _, inputStatus in
                guard let self, !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            guard status == .haveData, packet.packetCount > 0, packet.byteLength > 0 else { return }

            let payload = Data(bytes: packet.data, count: Int(packet.byteLength))
            let pts = CMTimeAdd(basePTS ?? .zero, CMTime(value: encodedFrames * 1024, timescale: CMTimeScale(Self.sampleRate)))
            encodedFrames += 1
            output(Self.adtsHeader(length: payload.count) + payload, pts)
        }
    }

    private static func adtsHeader(length: Int) -> Data {
        let frameLength = length + 7
        let profile = 1           // AAC LC (object type 2) - 1
        let frequencyIndex = 3    // 48 kHz
        let channelConfig = channels
        return Data([
            0xFF, 0xF1,
            UInt8((profile << 6) | (frequencyIndex << 2) | (channelConfig >> 2)),
            UInt8(((channelConfig & 3) << 6) | (frameLength >> 11)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 7) << 5) | 0x1F),
            0xFC,
        ])
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
