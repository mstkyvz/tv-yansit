import CoreMedia
import Foundation
import VideoToolbox

/// Ekran karelerini donanim (VideoToolbox) ile H.264'e kodlar ve Annex B bicimine cevirir.
final class VideoEncoder {
    typealias Output = (_ annexB: Data, _ pts: CMTime, _ isKeyframe: Bool) -> Void

    private var session: VTCompressionSession?
    private let output: Output

    init(width: Int, height: Int, fps: Int, bitrate: Int, output: @escaping Output) throws {
        self.output = output

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else {
            throw NSError(domain: "TVYansit", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "H.264 kodlayıcı açılamadı (\(status))"])
        }

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,   // B-kare yok: DTS = PTS
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            // Ani hareketlerde tamponu tasirmamak icin ust sinir (bayt/saniye)
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8 * 2, 1] as CFArray,
            // Saniyede bir anahtar kare: yayina baglanan TV en fazla 1 sn bekler
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handle(sampleBuffer)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let block = sampleBuffer.dataBuffer,
              let format = sampleBuffer.formatDescription else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var annexB = Data([0, 0, 0, 1, 0x09, 0xF0])   // Access Unit Delimiter
        if isKeyframe {
            for parameterSet in Self.parameterSets(format) {
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(parameterSet)
            }
        }

        // AVCC (4 bayt uzunluk + NAL) -> Annex B (baslangic kodu + NAL)
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let raw = UnsafeRawPointer(pointer)
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(Data(bytes: raw + offset, count: nalLength))
            offset += nalLength
        }

        output(annexB, sampleBuffer.presentationTimeStamp, isKeyframe)
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: nil)
        return (0 ..< count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}
