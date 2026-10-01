import CoreImage
import Foundation
import ScreenCaptureKit

/// Secilen ekran veya pencereyi ScreenCaptureKit ile yakalar.
///  - Tarayici modu: her kare JPEG'e cevrilip FrameStore'a konur (MJPEG).
///  - TV oynatici modu: kareler sabit hizda H.264'e, sistem sesi AAC'ye kodlanip TSBroadcaster'a gider.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Mode {
        case jpeg
        case video(bitrate: Int, audio: Bool)
    }

    private let store: FrameStore
    private let broadcaster: TSBroadcaster
    private let sampleQueue = DispatchQueue(label: "tvyansit.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "tvyansit.audio", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var stream: SCStream?

    // TV oynatici modu
    private var mode: Mode = .jpeg
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var frameTimer: DispatchSourceTimer?
    private var lastPixelBuffer: CVPixelBuffer?
    private var frameDuration = CMTime(value: 1, timescale: 30)

    private let qualityLock = NSLock()
    private var _quality: Double = 0.6
    /// JPEG kalitesi (0...1). Yayin sirasinda degistirilebilir.
    var quality: Double {
        get { qualityLock.lock(); defer { qualityLock.unlock() }; return _quality }
        set { qualityLock.lock(); _quality = newValue; qualityLock.unlock() }
    }

    /// Yakalama beklenmedik sekilde durursa (pencere kapandi vb.) ana kuyrukta cagrilir.
    var onStop: ((String) -> Void)?

    init(store: FrameStore, broadcaster: TSBroadcaster) {
        self.store = store
        self.broadcaster = broadcaster
    }

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool, mode: Mode) async throws {
        await stop()
        self.mode = mode

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.showsCursor = showsCursor
        config.queueDepth = 6
        config.scalesToFit = true

        var withAudio = false
        switch mode {
        case .jpeg:
            config.pixelFormat = kCVPixelFormatType_32BGRA
        case .video(let bitrate, let audio):
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            if audio {
                config.capturesAudio = true
                config.sampleRate = AudioEncoder.sampleRate
                config.channelCount = AudioEncoder.channels
                config.excludesCurrentProcessAudio = true
                withAudio = true
            }
            try startVideoPipeline(width: width, height: height, fps: fps, bitrate: bitrate, audio: audio)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if withAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        do {
            try await stream.startCapture()
        } catch {
            stopVideoPipeline()
            throw error
        }
        self.stream = stream
    }

    func stop() async {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        stopVideoPipeline()
    }

    // MARK: - TV oynatici hatti

    private func startVideoPipeline(width: Int, height: Int, fps: Int, bitrate: Int, audio: Bool) throws {
        broadcaster.prepare(hasAudio: audio)
        let broadcaster = self.broadcaster
        videoEncoder = try VideoEncoder(width: width, height: height, fps: fps, bitrate: bitrate) { data, pts, keyframe in
            broadcaster.video(data, pts: pts, isKeyframe: keyframe)
        }
        audioEncoder = audio ? AudioEncoder { data, pts in broadcaster.audio(data, pts: pts) } : nil
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        // Ekran degismediginde ScreenCaptureKit kare gondermez; TV oynaticisi ise
        // surekli kare bekler. Bu yuzden son kare sabit hizda tekrar kodlanir.
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.lastPixelBuffer else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.videoEncoder?.encode(buffer, pts: now, duration: self.frameDuration)
        }
        timer.resume()
        frameTimer = timer
    }

    private func stopVideoPipeline() {
        frameTimer?.cancel()
        frameTimer = nil
        sampleQueue.sync {
            lastPixelBuffer = nil
            videoEncoder?.invalidate()
            videoEncoder = nil
        }
        audioQueue.sync { audioEncoder = nil }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .audio {
            audioEncoder?.encode(sampleBuffer)
            return
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        switch mode {
        case .jpeg:
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            if let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) {
                store.publish(jpeg)
            }
        case .video:
            // Zamanlayici bir sonraki tikte bu kareyi kodlar
            lastPixelBuffer = pixelBuffer
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.onStop?(error.localizedDescription)
        }
    }
}
