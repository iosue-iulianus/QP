import SwiftUI

/// QuPi: Menu bar media player.
/// Dropdown shows poster carousels; selecting items opens a player window.
@main struct MyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
#if os(macOS)
        MenuBarExtra {
            MenuBarContentView()
                .environment(appState)
        } label: {
            Image(systemName: "play.square.stack")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Player", id: "video-player", for: MediaItem.self) { $item in
            // Non-optional binding so auto-continue can swap the played item.
            if let itemBinding = Binding($item) {
                PlayerView(item: itemBinding)
                    .environment(appState)
            }
        }
        .defaultSize(width: 780, height: 460)

        // Music gets its own vertical mini-player window.
        WindowGroup("Music", id: "music-player", for: MediaItem.self) { $item in
            if let itemBinding = Binding($item) {
                PlayerView(item: itemBinding)
                    .environment(appState)
            }
        }
        .defaultSize(width: 340, height: 660)

        Settings {
            SettingsView()
                .environment(appState)
        }
#else
        WindowGroup {
            Text("QuPi runs as a macOS menu bar app.")
                .padding()
        }
#endif
    }
}
