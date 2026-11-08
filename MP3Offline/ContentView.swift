import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var player: PlayerManager
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if player.tracks.isEmpty {
                    Spacer()
                    Text("Chưa có bài hát nào.\nBấm + để thêm file mp3.")
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.mp3],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { player.importFiles(urls) }
            }
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
            HStack(spacing: 40) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
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
