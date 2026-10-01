import AppKit
import Foundation
import ScreenCaptureKit

struct CaptureSource: Identifiable {
    enum Kind { case display, window }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: NSImage?
    var thumbnail: NSImage?
    let display: SCDisplay?
    let window: SCWindow?

    var aspect: CGFloat {
        let frame = display?.frame ?? window?.frame ?? .zero
        return frame.height > 0 ? frame.width / frame.height : 16 / 9
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case displays = "Ekranlar"
        case windows = "Pencereler"
        var id: String { rawValue }
    }

    enum StreamMode: String, CaseIterable, Identifiable {
        case browser
        case tvPlayer
        var id: String { rawValue }
        var title: String { self == .browser ? "Tarayıcı · düşük gecikme" : "TV oynatıcı · yüksek kalite" }
    }

    @Published var tab: Tab = .displays
    @Published private(set) var displays: [CaptureSource] = []
    @Published private(set) var windows: [CaptureSource] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var browserClients = 0
    @Published private(set) var playerClients = 0
    var clientCount: Int { browserClients + playerClients }
    @Published private(set) var addresses: [LocalAddress] = []
    @Published private(set) var needsPermission = false
    @Published var message: String?

    @Published var port: Int = UserDefaults.standard.object(forKey: "port") as? Int ?? 8080 {
        didSet { UserDefaults.standard.set(port, forKey: "port") }
    }
    @Published var fps: Int = UserDefaults.standard.object(forKey: "fps") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(fps, forKey: "fps"); settingsChanged() }
    }
    @Published var maxWidth: Int = UserDefaults.standard.object(forKey: "maxWidth") as? Int ?? 1280 {
        didSet { UserDefaults.standard.set(maxWidth, forKey: "maxWidth"); settingsChanged() }
    }
    @Published var quality: Double = UserDefaults.standard.object(forKey: "quality") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(quality, forKey: "quality"); engine.quality = quality }
    }
    @Published var showsCursor: Bool = UserDefaults.standard.object(forKey: "showsCursor") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsCursor, forKey: "showsCursor"); settingsChanged() }
    }

    // MARK: TV oynatici (DLNA) ayarlari

    @Published var streamMode: StreamMode = StreamMode(rawValue: UserDefaults.standard.string(forKey: "streamMode") ?? "") ?? .browser {
        didSet {
            UserDefaults.standard.set(streamMode.rawValue, forKey: "streamMode")
            guard oldValue != streamMode else { return }
            if streamMode == .tvPlayer, devices.isEmpty { Task { await discoverDevices() } }
            if isRunning { Task { await stop() } }
        }
    }
    @Published var videoHeight: Int = UserDefaults.standard.object(forKey: "videoHeight") as? Int ?? 1080 {
        didSet { UserDefaults.standard.set(videoHeight, forKey: "videoHeight"); settingsChanged() }
    }
    @Published var videoFPS: Int = UserDefaults.standard.object(forKey: "videoFPS") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(videoFPS, forKey: "videoFPS"); settingsChanged() }
    }
    @Published var bitrateMbps: Int = UserDefaults.standard.object(forKey: "bitrateMbps") as? Int ?? 12 {
        didSet { UserDefaults.standard.set(bitrateMbps, forKey: "bitrateMbps"); settingsChanged() }
    }
    @Published var sendsAudio: Bool = UserDefaults.standard.object(forKey: "sendsAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sendsAudio, forKey: "sendsAudio"); settingsChanged() }
    }
    @Published private(set) var devices: [DLNADevice] = []
    @Published private(set) var isDiscovering = false
    @Published var selectedDeviceID: String? = UserDefaults.standard.string(forKey: "deviceID") {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "deviceID") }
    }
    @Published private(set) var tvVolume: Int?
    @Published private(set) var tvMuted = false
    private var volumeTask: Task<Void, Never>?
    /// TV'ye son gonderilen akisin cozunurlugu ve ses durumu; degisirse TV akisi yeniden acar
    private var playingFormat: (height: Int, audio: Bool)?

    var selectedDevice: DLNADevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private let store = FrameStore()
    private lazy var server = HTTPServer(store: store)
    private lazy var engine = CaptureEngine(store: store, broadcaster: server.broadcaster)
    private var ownApplications: [SCRunningApplication] = []
    private var restartTask: Task<Void, Never>?

    init() {
        engine.quality = quality
        engine.onStop = { [weak self] reason in
            guard let self, self.isRunning else { return }
            self.message = "Yakalama durdu: \(reason). Baska bir kaynak sec."
        }
        server.onClientCountChange = { [weak self] count in
            self?.browserClients = count
        }
        server.broadcaster.onClientCountChange = { [weak self] count in
            self?.playerClients = count
        }
        if streamMode == .tvPlayer {
            Task { await discoverDevices() }
        }
        refreshAddresses()
    }

    var sources: [CaptureSource] { tab == .displays ? displays : windows }

    var selected: CaptureSource? {
        guard let selectedID else { return nil }
        return (displays + windows).first { $0.id == selectedID }
    }

    var primaryURL: String? {
        addresses.first.map { "http://\($0.ip):\(port)" }
    }

    // MARK: - Kaynaklar

    func refreshAddresses() {
        addresses = LocalAddresses.ordered()
    }

    func refreshSources() async {
        refreshAddresses()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            needsPermission = false
        } catch {
            needsPermission = true
            return
        }

        let ownBundle = Bundle.main.bundleIdentifier ?? "com.tvyansit.app"
        ownApplications = content.applications.filter { $0.bundleIdentifier == ownBundle }

        displays = content.displays.enumerated().map { index, display in
            let isMain = display.displayID == CGMainDisplayID()
            return CaptureSource(
                id: "d\(display.displayID)",
                kind: .display,
                title: isMain ? "Ana ekran" : "Ekran \(index + 1)",
                subtitle: "\(Int(display.frame.width)) × \(Int(display.frame.height))",
                icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil),
                display: display,
                window: nil
            )
        }

        windows = content.windows
            .filter { window in
                guard let app = window.owningApplication,
                      app.bundleIdentifier != ownBundle,
                      window.windowLayer == 0,
                      window.frame.width >= 120, window.frame.height >= 80
                else { return false }
                return true
            }
            .sorted {
                let a = $0.owningApplication?.applicationName ?? ""
                let b = $1.owningApplication?.applicationName ?? ""
                return a == b ? ($0.title ?? "") < ($1.title ?? "") : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { window in
                let app = window.owningApplication
                let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Adsız pencere"
                return CaptureSource(
                    id: "w\(window.windowID)",
                    kind: .window,
                    title: title,
                    subtitle: app?.applicationName ?? "",
                    icon: app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon },
                    display: nil,
                    window: window
                )
            }

        if selectedID == nil || selected == nil {
            selectedID = displays.first(where: { $0.display?.displayID == CGMainDisplayID() })?.id ?? displays.first?.id
        }

        await loadThumbnails()
    }

    private func loadThumbnails() async {
        guard #available(macOS 14.0, *) else { return }
        for index in displays.indices {
            if let image = await thumbnail(for: displays[index]) { displays[index].thumbnail = image }
        }
        for index in windows.indices {
            if let image = await thumbnail(for: windows[index]) { windows[index].thumbnail = image }
        }
    }

    @available(macOS 14.0, *)
    private func thumbnail(for source: CaptureSource) async -> NSImage? {
        guard let filter = makeFilter(for: source) else { return nil }
        let config = SCStreamConfiguration()
        let width = 360
        config.width = width
        config.height = max(2, Int(CGFloat(width) / source.aspect))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func makeFilter(for source: CaptureSource) -> SCContentFilter? {
        if let display = source.display {
            return SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        }
        if let window = source.window {
            return SCContentFilter(desktopIndependentWindow: window)
        }
        return nil
    }

    // MARK: - Yayin

    func select(_ source: CaptureSource) {
        selectedID = source.id
        message = nil
        if isRunning { restartCapture() }
    }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    func start() async {
        message = nil
        guard selected != nil else {
            message = "Önce bir ekran veya pencere seç."
            return
        }
        if streamMode == .tvPlayer, selectedDevice == nil {
            message = "Önce yayın yapılacak TV'yi seç."
            return
        }
        do {
            try server.start(port: UInt16(clamping: port))
        } catch {
            message = "Sunucu başlatılamadı (port \(port) kullanımda olabilir): \(error.localizedDescription)"
            return
        }
        isRunning = true
        refreshAddresses()
        do {
            try await startCapture()
        } catch {
            message = "Yakalama başlatılamadı: \(error.localizedDescription)"
            await stop()
            return
        }
        if streamMode == .tvPlayer {
            await sendToTV()
        }
    }

    /// TV'ye "su adresi oynat" komutunu gonderir.
    func sendToTV() async {
        guard let device = selectedDevice, let ip = addresses.first?.ip else { return }
        do {
            try await DLNA.play(device, streamURL: "http://\(ip):\(port)/canli.ts", title: "TV Yansıt")
            playingFormat = (videoHeight, sendsAudio)
            await refreshVolume()
        } catch {
            message = "TV yayını açamadı: \(error.localizedDescription)"
        }
    }

    func stop() async {
        restartTask?.cancel()
        if streamMode == .tvPlayer, isRunning, let device = selectedDevice {
            await DLNA.stop(device)
        }
        await engine.stop()
        server.stop()
        isRunning = false
        playingFormat = nil
        browserClients = 0
        playerClients = 0
    }

    private func startCapture() async throws {
        guard let source = selected, let filter = makeFilter(for: source) else { return }
        switch streamMode {
        case .browser:
            let (width, height) = outputSize(for: source)
            try await engine.start(filter: filter, width: width, height: height, fps: fps,
                                   showsCursor: showsCursor, mode: .jpeg)
        case .tvPlayer:
            // TV oynaticilari standart 16:9 boyutlari sever; farkli oranlar siyah bantla sigdirilir
            let height = videoHeight
            let width = height * 16 / 9
            try await engine.start(filter: filter, width: width, height: height, fps: videoFPS,
                                   showsCursor: showsCursor,
                                   mode: .video(bitrate: bitrateMbps * 1_000_000, audio: sendsAudio))
        }
    }

    /// Kaynak degisince TV'deki sayfa yeniden yuklenmeden yeni goruntuye gecer.
    private func restartCapture() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startCapture()
                if self.streamMode == .tvPlayer, let playing = self.playingFormat,
                   playing.height != self.videoHeight || playing.audio != self.sendsAudio {
                    await self.sendToTV()
                }
            } catch {
                self.message = "Yakalama başlatılamadı: \(error.localizedDescription)"
            }
        }
    }

    private func settingsChanged() {
        if isRunning { restartCapture() }
    }

    private func outputSize(for source: CaptureSource) -> (Int, Int) {
        let frame = source.display?.frame ?? source.window?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
        // Retina ekranda kaynak piksel genisligi noktanin yaklasik 2 kati
        let sourceWidth = Int(frame.width * 2)
        var width = min(maxWidth, sourceWidth)
        var height = Int((CGFloat(width) * frame.height / max(frame.width, 1)).rounded())
        width -= width % 2
        height -= height % 2
        return (max(width, 2), max(height, 2))
    }

    // MARK: - TV (DLNA)

    func discoverDevices() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        refreshAddresses()
        let found = await DLNA.discover(localIP: addresses.first?.ip)
        isDiscovering = false
        devices = found
        if selectedDevice == nil {
            selectedDeviceID = found.first?.id
        }
    }

    func refreshVolume() async {
        guard let device = selectedDevice else { return }
        tvVolume = await DLNA.volume(device)
        tvMuted = await DLNA.isMuted(device) ?? false
    }

    func changeVolume(by delta: Int) {
        setVolume((tvVolume ?? 20) + delta)
    }

    /// Kaydirici hizli hareket edince TV'ye her adim yerine son deger gonderilir.
    func setVolume(_ value: Int) {
        let clamped = max(0, min(100, value))
        tvVolume = clamped
        guard let device = selectedDevice else { return }
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await DLNA.setVolume(device, clamped)
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    func toggleMute() async {
        guard let device = selectedDevice else { return }
        let muted = !tvMuted
        do {
            try await DLNA.setMuted(device, muted)
            tvMuted = muted
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Izin

    func openPrivacySettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
