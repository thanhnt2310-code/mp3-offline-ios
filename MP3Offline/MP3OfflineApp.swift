import SwiftUI

@main
struct MP3OfflineApp: App {
    @StateObject private var player = PlayerManager()
    @StateObject private var importer = FolderImporter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(importer)
        }
    }
}
