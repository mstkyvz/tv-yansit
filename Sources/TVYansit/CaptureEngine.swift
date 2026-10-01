import CoreImage
import Foundation
import ScreenCaptureKit

/// Secilen ekran veya pencereyi ScreenCaptureKit ile yakalar, JPEG'e cevirip FrameStore'a koyar.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let store: FrameStore
    private let sampleQueue = DispatchQueue(label: "tvyansit.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var stream: SCStream?

    private let qualityLock = NSLock()
    private var _quality: Double = 0.6
    /// JPEG kalitesi (0...1). Yayin sirasinda degistirilebilir.
    var quality: Double {
        get { qualityLock.lock(); defer { qualityLock.unlock() }; return _quality }
        set { qualityLock.lock(); _quality = newValue; qualityLock.unlock() }
    }

    /// Yakalama beklenmedik sekilde durursa (pencere kapandi vb.) ana kuyrukta cagrilir.
    var onStop: ((String) -> Void)?

    init(store: FrameStore) {
        self.store = store
    }

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool) async throws {
        await stop()
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.queueDepth = 3
        config.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        if let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) {
            store.publish(jpeg)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.onStop?(error.localizedDescription)
        }
    }
}
