import AVFoundation
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

@main
struct PlayerApp: App {
    @StateObject private var player = LocalPlayer()
    @State private var choosing = false

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        Button("匯入 MP3") { choosing = true }
                        Text(player.current?.deletingPathExtension().lastPathComponent ?? "選擇歌曲")
                        Slider(value: Binding(get: { player.position }, set: { player.seek($0) }),
                               in: 0...max(player.duration, 1))
                            .disabled(player.current == nil)
                        HStack {
                            Button("上一首") { player.step(-1) }
                            Spacer()
                            Button(player.playing ? "暫停" : "播放") { player.toggle() }
                            Spacer()
                            Button("下一首") { player.step(1) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.current == nil)
                        Toggle("隨機播放", isOn: $player.shuffle)
                        if let error = player.error { Text(error).foregroundStyle(.red) }
                    }
                    Section("本機歌曲") {
                        ForEach(player.tracks, id: \.self) { track in
                            Button(track.deletingPathExtension().lastPathComponent) { player.select(track) }
                        }
                    }
                }
                .navigationTitle("離線 MP3")
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.mp3], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): player.importTracks(urls)
                    case .failure(let error): player.error = error.localizedDescription
                    }
                }
            }
        }
    }
}

@MainActor
final class LocalPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [URL] = []
    @Published private(set) var current: URL?
    @Published private(set) var playing = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published var shuffle = false
    @Published var error: String?

    private let directory = URL.documentsDirectory.appendingPathComponent("Music", isDirectory: true)
    private let session = AVAudioSession.sharedInstance()
    private var audio: AVAudioPlayer?
    private var resumeAfterInterruption = false
    private var timer: Timer?

    override init() {
        super.init()
        reloadTracks()
        if let first = tracks.first { select(first, autoplay: false) }
        registerCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                                               name: AVAudioSession.interruptionNotification, object: session)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
    }

    func importTracks(_ urls: [URL]) {
        error = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let target = directory.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                try FileManager.default.copyItem(at: url, to: target)
            }
        } catch { self.error = error.localizedDescription }
        reloadTracks()
        if current == nil, let first = tracks.first { select(first, autoplay: false) }
    }

    private func reloadTracks() {
        tracks = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func select(_ url: URL, autoplay: Bool = true) {
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            audio?.stop()
            resumeAfterInterruption = false
            audio = next
            current = url
            next.delegate = self
            duration = next.duration
            error = nil
            publishState()
            if autoplay { play() }
        } catch { self.error = error.localizedDescription }
    }

    func toggle() { if playing { pause() } else { play() } }

    private func play() {
        guard let audio else { return }
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            guard audio.play() else {
                error = "無法開始播放。"
                return
            }
            error = nil
            publishState()
        } catch { self.error = error.localizedDescription }
    }

    private func pause() {
        resumeAfterInterruption = false
        audio?.pause()
        publishState()
    }

    func seek(_ time: TimeInterval) {
        guard let audio, time.isFinite else { return }
        audio.currentTime = min(max(time, 0), audio.duration)
        publishState()
    }

    func step(_ direction: Int) {
        guard let current, let index = tracks.firstIndex(of: current) else { return }
        let ordered = tracks[(index + direction + tracks.count) % tracks.count]
        let next = shuffle && direction > 0 ? tracks.filter { $0 != current }.randomElement() ?? ordered : ordered
        select(next)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard audio === player else { return }
            if flag, tracks.count > 1 { step(1) }
            else { publishState() }
        }
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            resumeAfterInterruption = playing
            audio?.pause()
            publishState()
        } else {
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let resume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            resumeAfterInterruption = false
            if resume { play() }
        }
    }

    private func registerCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.step(1) }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.step(-1) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(time) }
            return .success
        }
    }

    private func updatePosition() {
        if let audio { position = audio.currentTime }
    }

    private func publishState() {
        guard let audio, let current else { return }
        updatePosition()
        playing = audio.isPlaying
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.deletingPathExtension().lastPathComponent,
            MPMediaItemPropertyPlaybackDuration: audio.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audio.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: audio.isPlaying ? 1.0 : 0.0,
        ]
    }
}

