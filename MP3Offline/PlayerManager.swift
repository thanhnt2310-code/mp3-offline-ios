import AVFoundation
import MediaPlayer
import Combine

struct Track: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var title: String
}

final class PlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [Track] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Thư mục lưu nhạc của app (Documents). Hiện trong app Files > On My iPhone > MP3 Offline.
    static var musicDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var currentTitle: String {
        guard let i = currentIndex, tracks.indices.contains(i) else { return "Chưa phát bài nào" }
        return tracks[i].title
    }

    override init() {
        super.init()
        setupSession()
        setupRemoteCommands()
        reload()
    }

    // MARK: - Thư viện

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.musicDir, includingPropertiesForKeys: nil)) ?? []
        let current = currentIndex.flatMap { tracks.indices.contains($0) ? tracks[$0].id : nil }
        tracks = files
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { Track(id: $0, title: $0.deletingPathExtension().lastPathComponent) }
        if let current { currentIndex = tracks.firstIndex { $0.id == current } }
    }

    /// Copy file mp3 được chọn vào thư mục app, bỏ qua file đã có.
    func importFiles(_ urls: [URL]) {
        for src in urls {
            let accessing = src.startAccessingSecurityScopedResource()
            defer { if accessing { src.stopAccessingSecurityScopedResource() } }
            guard src.pathExtension.lowercased() == "mp3" else { continue }
            let dest = Self.musicDir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            try? FileManager.default.copyItem(at: src, to: dest)
        }
        reload()
    }

    func delete(at offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: tracks[i].url) }
        reload()
    }

    // MARK: - Phát nhạc

    func play(index: Int) {
        guard tracks.indices.contains(index) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: tracks[index].url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            currentIndex = index
            duration = p.duration
            currentTime = 0
            isPlaying = true
            startTimer()
            updateNowPlaying()
        } catch {
            print("Không phát được: \(error)")
        }
    }

    func togglePlay() {
        guard let p = player else {
            if !tracks.isEmpty { play(index: 0) }
            return
        }
        if p.isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true }
        updateNowPlaying()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        play(index: ((currentIndex ?? -1) + 1) % tracks.count)
    }

    func previous() {
        guard !tracks.isEmpty else { return }
        if currentTime > 3 { seek(0); return }
        play(index: ((currentIndex ?? 0) - 1 + tracks.count) % tracks.count)
    }

    func seek(_ time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
        updateNowPlaying()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { next() }
    }

    // MARK: - Hệ thống

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
        }
    }

    private func setupSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.isPlaying = false
            } else if let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                self.player?.play()
                self.isPlaying = true
            }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            if self?.isPlaying == false { self?.togglePlay() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            if self?.isPlaying == true { self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }
}
