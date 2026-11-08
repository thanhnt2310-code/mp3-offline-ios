import AVFoundation
import MediaPlayer
import Combine

struct Track: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var title: String
}

enum RepeatMode: Int {
    case off, all, one
}

final class PlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [Track] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    /// Trộn bài (shuffle) và lặp lại (repeat), được nhớ lại sau khi mở app.
    @Published var shuffleOn: Bool = UserDefaults.standard.bool(forKey: "shuffleOn") {
        didSet { UserDefaults.standard.set(shuffleOn, forKey: "shuffleOn") }
    }
    @Published var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeatMode")) ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }

    /// Thời gian crossfade (giây). 0 = tắt. Được nhớ lại sau khi mở app.
    @Published var crossfadeSeconds: Double = UserDefaults.standard.object(forKey: "crossfadeSeconds") as? Double ?? 6 {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "crossfadeSeconds") }
    }

    private var player: AVAudioPlayer?
    /// Bài cũ đang mờ dần trong lúc crossfade.
    private var outgoing: AVAudioPlayer?
    private var fadeTriggered = false
    private var timer: Timer?

    /// Thứ tự phát hiện tại (danh sách chỉ số của `tracks`) và vị trí đang phát trong đó.
    private var order: [Int] = []
    private var pos = 0

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
        let currentURL = currentIndex.flatMap { tracks.indices.contains($0) ? tracks[$0].id : nil }
        tracks = files
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { Track(id: $0, title: $0.deletingPathExtension().lastPathComponent) }
        if let currentURL { currentIndex = tracks.firstIndex { $0.id == currentURL } }
        rebuildOrder(keeping: currentIndex)
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

    // MARK: - Thứ tự phát (shuffle)

    /// Dựng lại hàng chờ. Bài đang phát (nếu có) luôn đứng đầu khi trộn.
    private func rebuildOrder(keeping current: Int?) {
        var idx = Array(tracks.indices)
        if shuffleOn {
            idx.shuffle()
            if let c = current, let at = idx.firstIndex(of: c) {
                idx.remove(at: at)
                idx.insert(c, at: 0)
            }
            pos = 0
        } else {
            pos = current ?? 0
        }
        order = idx
    }

    func toggleShuffle() {
        shuffleOn.toggle()
        rebuildOrder(keeping: currentIndex)
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Nút "Phát ngẫu nhiên": bật trộn bài và phát một bài bất kỳ.
    func shuffleAll() {
        guard !tracks.isEmpty else { return }
        shuffleOn = true
        play(index: Int.random(in: tracks.indices))
    }

    // MARK: - Phát nhạc

    /// Người dùng chọn một bài: dựng lại hàng chờ quanh bài đó rồi phát.
    func play(index: Int) {
        guard tracks.indices.contains(index) else { return }
        rebuildOrder(keeping: index)
        playTrack(index)
    }

    private func playTrack(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: tracks[index].url)
            player?.stop()
            outgoing?.stop()
            outgoing = nil
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            currentIndex = index
            duration = p.duration
            currentTime = 0
            isPlaying = true
            fadeTriggered = false
            startTimer()
            updateNowPlaying()
        } catch {
            print("Không phát được: \(error)")
        }
    }

    // MARK: - Crossfade

    /// Bài sắp hết: chồng bài kế tiếp vào, bài cũ nhỏ dần, bài mới to dần.
    private func startCrossfade(to index: Int) {
        guard tracks.indices.contains(index), let old = player else { return }
        do {
            let d = crossfadeSeconds
            let p = try AVAudioPlayer(contentsOf: tracks[index].url)
            old.delegate = nil
            p.delegate = self
            p.volume = 0
            p.prepareToPlay()
            p.play()
            p.setVolume(1, fadeDuration: d)
            old.setVolume(0, fadeDuration: d)
            outgoing = old
            player = p
            currentIndex = index
            duration = p.duration
            currentTime = 0
            fadeTriggered = false
            updateNowPlaying()
            DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.3) { [weak self] in
                old.stop()
                if self?.outgoing === old { self?.outgoing = nil }
            }
        } catch {
            print("Crossfade lỗi: \(error)")
        }
    }

    /// Kết thúc crossfade ngay (khi tạm dừng, tua, bị gián đoạn).
    private func finishFade() {
        guard outgoing != nil else { return }
        outgoing?.stop()
        outgoing = nil
        player?.volume = 1
    }

    func togglePlay() {
        finishFade()
        guard let p = player else {
            if !tracks.isEmpty { play(index: shuffleOn ? Int.random(in: tracks.indices) : 0) }
            return
        }
        if p.isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true }
        updateNowPlaying()
    }

    /// Chuyển vị trí sang bài kế tiếp trong hàng chờ, trả về chỉ số bài đó.
    /// manual = true: người dùng bấm "bài tiếp" (hết danh sách thì quay lại đầu).
    /// manual = false: bài tự hết (hết danh sách và không lặp thì trả về nil để dừng).
    private func advance(manual: Bool) -> Int? {
        guard !order.isEmpty else { return nil }
        var newPos = pos + 1
        if newPos >= order.count {
            if !manual && repeatMode == .off { return nil }
            newPos = 0
            if shuffleOn { rebuildOrder(keeping: nil) } // trộn lại vòng mới
        }
        pos = newPos
        return order[pos]
    }

    func next(manual: Bool = true) {
        if let i = advance(manual: manual) { playTrack(i) } else { stop() }
    }

    func previous() {
        guard !order.isEmpty else { return }
        if currentTime > 3 { seek(0); return }
        pos = pos - 1 < 0 ? order.count - 1 : pos - 1
        playTrack(order[pos])
    }

    private func stop() {
        finishFade()
        player?.pause()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        updateNowPlaying()
    }

    func seek(_ time: TimeInterval) {
        finishFade()
        player?.currentTime = time
        currentTime = time
        updateNowPlaying()
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        guard flag, finished === player else { return }
        if repeatMode == .one, let i = currentIndex {
            playTrack(i)
        } else {
            next(manual: false)
        }
    }

    // MARK: - Hệ thống

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        guard crossfadeSeconds > 0, isPlaying, outgoing == nil,
              !fadeTriggered, repeatMode != .one else { return }
        let d = crossfadeSeconds
        // Bài quá ngắn thì không crossfade.
        guard p.duration > d * 2 + 1, p.duration - p.currentTime <= d else { return }
        fadeTriggered = true
        if let i = advance(manual: false) { startCrossfade(to: i) }
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
                self.finishFade()
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
