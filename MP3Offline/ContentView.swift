import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var importer: FolderImporter
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ImportBar()
                Divider()
                if player.tracks.isEmpty {
                    Spacer()
                    Text("Chưa có bài hát nào.\nChọn thư mục nguồn rồi bấm Import.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(Array(player.tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.play(index: index)
                            } label: {
                                HStack {
                                    Image(systemName: player.currentIndex == index ? "speaker.wave.2.fill" : "music.note")
                                        .frame(width: 24)
                                    Text(track.title).lineLimit(1)
                                }
                            }
                            .foregroundStyle(player.currentIndex == index ? Color.accentColor : Color.primary)
                        }
                        .onDelete(perform: player.delete)
                    }
                    .listStyle(.plain)
                }
                PlayerBar()
            }
            .navigationTitle("MP3 Offline")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { player.shuffleAll() } label: {
                        Label("Phát ngẫu nhiên", systemImage: "shuffle")
                    }
                    .disabled(player.tracks.isEmpty)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Crossfade", selection: $player.crossfadeSeconds) {
                            Text("Crossfade: Tắt").tag(0.0)
                            Text("Crossfade: 3 giây").tag(3.0)
                            Text("Crossfade: 6 giây").tag(6.0)
                            Text("Crossfade: 9 giây").tag(9.0)
                            Text("Crossfade: 12 giây").tag(12.0)
                        }
                    } label: {
                        Image(systemName: "waveform.path")
                    }
                    Menu {
                        Button { showFilePicker = true } label: {
                            Label("Thêm file mp3 thủ công", systemImage: "doc.badge.plus")
                        }
                        Button { importer.resetHistory() } label: {
                            Label("Cho phép import lại bài đã xóa", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.mp3],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { player.importFiles(urls) }
            }
        }
        .onChange(of: scenePhase) { phase in
            // Mở lại app: quét lại thư mục Documents (file thêm bằng cáp / Files).
            if phase == .active { player.reload() }
        }
    }
}

/// Thanh import: chọn thư mục nguồn một lần, sau đó chỉ cần bấm "Import bài mới".
struct ImportBar: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var importer: FolderImporter
    @State private var showFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    importer.importNew(into: player)
                } label: {
                    Label("Import bài mới", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importer.isImporting || importer.folderName == nil)
                if importer.isImporting { ProgressView() }
                Spacer()
                Button(importer.folderName == nil ? "Chọn thư mục" : "Đổi thư mục") {
                    showFolderPicker = true
                }
                .font(.subheadline)
            }
            if let name = importer.folderName {
                Text("Thư mục nguồn: \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let s = importer.status {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(
                onPick: { url in
                    importer.setFolder(url)
                    showFolderPicker = false
                },
                onCancel: { showFolderPicker = false }
            )
        }
    }
}

struct PlayerBar: View {
    @EnvironmentObject var player: PlayerManager

    var body: some View {
        VStack(spacing: 8) {
            Text(player.currentTitle)
                .font(.headline)
                .lineLimit(1)
            Slider(value: Binding(get: { player.currentTime },
                                  set: { player.seek($0) }),
                   in: 0...max(player.duration, 1))
            HStack {
                Text(format(player.currentTime))
                Spacer()
                Text(format(player.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.shuffleOn ? Color.accentColor : Color.secondary)
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                }
            }
            .font(.title2)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t.isFinite ? t : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
