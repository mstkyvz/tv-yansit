import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.needsPermission {
                permissionView
            } else {
                sourcePicker
            }
            Divider()
            settings
        }
        .frame(minWidth: 640, minHeight: 560)
        .task { await model.refreshSources() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshSources() }
        }
    }

    // MARK: - Ust bilgi

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                    Text(statusText).font(.headline)
                }
                if model.streamMode == .tvPlayer {
                    Text(model.selectedDevice.map { "Yayın \($0.name) üzerinde açılacak" } ?? "Aşağıdan bir TV seç")
                        .foregroundStyle(.secondary)
                } else if let url = model.primaryURL {
                    HStack(spacing: 6) {
                        Text("TV tarayıcısında aç:").foregroundStyle(.secondary)
                        Text(url)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Adresi kopyala")
                    }
                    if model.addresses.count > 1 {
                        Text("Diğer adresler: " + model.addresses.dropFirst().map { "\($0.ip) (\($0.interface))" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Ağ bağlantısı bulunamadı. Mac'i TV ile aynı Wi‑Fi'a bağla.")
                        .foregroundStyle(.orange)
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
            Spacer()
            Button {
                Task { await model.toggle() }
            } label: {
                Label(model.isRunning ? "Durdur" : "Yayını Başlat",
                      systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 130)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var statusText: String {
        guard model.isRunning else { return "Yayın kapalı" }
        let source = model.selected.map { $0.kind == .display ? $0.title : "\($0.subtitle) – \($0.title)" } ?? ""
        let viewers = model.clientCount == 0 ? "izleyen yok" : "\(model.clientCount) izleyici"
        return "Yayında: \(source) · \(viewers)"
    }

    // MARK: - Kaynak secimi

    private var sourcePicker: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(AppModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                Button {
                    Task { await model.refreshSources() }
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                if model.sources.isEmpty {
                    Text(model.tab == .windows ? "Açık pencere bulunamadı." : "Ekran bulunamadı.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(model.sources) { source in
                            SourceCard(source: source, isSelected: source.id == model.selected?.id)
                                .onTapGesture { model.select(source) }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Ekran kaydı izni gerekiyor").font(.title3.weight(.semibold))
            Text("Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı bölümünde TV Yansıt'ı aç, sonra uygulamayı kapatıp yeniden başlat.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button("Ayarları Aç") { model.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Tekrar Dene") { Task { await model.refreshSources() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Ayarlar

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Mod", selection: $model.streamMode) {
                    ForEach(AppModel.StreamMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
                HStack(spacing: 4) {
                    Text("Port")
                    TextField("", value: $model.port, format: .number.grouping(.never))
                        .frame(width: 60)
                        .disabled(model.isRunning)
                }
            }

            if model.streamMode == .browser {
                browserSettings
            } else {
                playerSettings
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var browserSettings: some View {
        HStack(spacing: 20) {
            Picker("Akıcılık", selection: $model.fps) {
                ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .frame(width: 150)

            Picker("Çözünürlük", selection: $model.maxWidth) {
                ForEach([640, 960, 1280, 1600, 1920], id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(width: 170)

            HStack(spacing: 6) {
                Text("Kalite")
                Slider(value: $model.quality, in: 0.2...0.95)
                    .frame(width: 110)
            }

            Toggle("İmleç", isOn: $model.showsCursor)
            Spacer()
        }
        .help("Görüntü takılıyorsa akıcılığı, çözünürlüğü veya kaliteyi düşür.")
    }

    private var playerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "tv")
                Picker("TV", selection: $model.selectedDeviceID) {
                    if model.devices.isEmpty {
                        Text(model.isDiscovering ? "Aranıyor…" : "TV bulunamadı").tag(String?.none)
                    }
                    ForEach(model.devices) { device in
                        Text(device.model.isEmpty ? device.name : "\(device.name) (\(device.model))")
                            .tag(String?.some(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(model.isRunning)

                if model.isDiscovering {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.discoverDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("TV'leri yeniden ara")
                    .disabled(model.isRunning)
                }

                Spacer()

                if model.isRunning, model.selectedDevice?.renderingControlURL != nil {
                    volumeControls
                }
            }

            HStack(spacing: 20) {
                Picker("Çözünürlük", selection: $model.videoHeight) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("4K").tag(2160)
                }
                .frame(width: 170)

                Picker("Akıcılık", selection: $model.videoFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .frame(width: 140)

                Picker("Bit hızı", selection: $model.bitrateMbps) {
                    ForEach([4, 8, 12, 20, 30, 50], id: \.self) { Text("\($0) Mbit/s").tag($0) }
                }
                .frame(width: 170)

                Toggle("Ses", isOn: $model.sendsAudio)
                Toggle("İmleç", isOn: $model.showsCursor)
                Spacer()
            }

            Text("Görüntü TV'nin kendi oynatıcısında açılır. Akıcı ve seslidir, ama 1–2 saniye gecikme olur. Takılırsa bit hızını düşür.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeControls: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.toggleMute() }
            } label: {
                Image(systemName: model.tvMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .help(model.tvMuted ? "Sesi aç" : "Sessize al")

            Button { model.changeVolume(by: -5) } label: { Image(systemName: "minus") }
                .help("Sesi kıs")
            Slider(
                value: Binding(
                    get: { Double(model.tvVolume ?? 0) },
                    set: { model.setVolume(Int($0.rounded())) }
                ),
                in: 0...100
            )
            .frame(width: 120)
            Button { model.changeVolume(by: 5) } label: { Image(systemName: "plus") }
                .help("Sesi aç")
            Text(model.tvVolume.map { "\($0)" } ?? "–")
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
        }
        .buttonStyle(.borderless)
    }
}

private struct SourceCard: View {
    let source: CaptureSource
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                if let thumbnail = source.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let icon = source.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                if source.kind == .window, let icon = source.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(source.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}
