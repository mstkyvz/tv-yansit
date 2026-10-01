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

    @Published var tab: Tab = .displays
    @Published private(set) var displays: [CaptureSource] = []
    @Published private(set) var windows: [CaptureSource] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0
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

    private let store = FrameStore()
    private lazy var engine = CaptureEngine(store: store)
    private lazy var server = HTTPServer(store: store)
    private var ownApplications: [SCRunningApplication] = []
    private var restartTask: Task<Void, Never>?

    init() {
        engine.quality = quality
        engine.onStop = { [weak self] reason in
            guard let self, self.isRunning else { return }
            self.message = "Yakalama durdu: \(reason). Baska bir kaynak sec."
        }
        server.onClientCountChange = { [weak self] count in
            self?.clientCount = count
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
        }
    }

    func stop() async {
        restartTask?.cancel()
        await engine.stop()
        server.stop()
        isRunning = false
        clientCount = 0
    }

    private func startCapture() async throws {
        guard let source = selected, let filter = makeFilter(for: source) else { return }
        let (width, height) = outputSize(for: source)
        try await engine.start(filter: filter, width: width, height: height, fps: fps, showsCursor: showsCursor)
    }

    /// Kaynak degisince TV'deki sayfa yeniden yuklenmeden yeni goruntuye gecer.
    private func restartCapture() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startCapture()
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

    // MARK: - Izin

    func openPrivacySettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
