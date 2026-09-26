import SwiftUI

struct PlaybackSettingsView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(SettingsKeys.movieAutoContinue) private var movieAutoContinue = MovieAutoContinue.off.rawValue
    @AppStorage(SettingsKeys.tvAutoContinue) private var tvAutoContinue = false
    @AppStorage(SettingsKeys.musicAutoContinue) private var musicAutoContinue = MusicAutoContinue.off.rawValue
    @AppStorage(SettingsKeys.continueMusic) private var continueMusic = ContinueMusicGrouping.byAlbumPlaylist.rawValue
    @AppStorage(SettingsKeys.continueTimeout) private var continueTimeout = ContinueTimeout.forever.rawValue

    var body: some View {
        Form {
            Section("Movies") {
                Picker(selection: $movieAutoContinue) {
                    Text("Off").tag(MovieAutoContinue.off.rawValue)
                    Text("Next in Series").tag(MovieAutoContinue.inSequence.rawValue)
                    Text("Same Director").tag(MovieAutoContinue.byDirector.rawValue)
                    Text("Same Lead Actor").tag(MovieAutoContinue.byLeadActor.rawValue)
                } label: {
                    Text("When a Movie Ends")
                    Text("Play the next movie in its series, or the next release by its director or lead actor.")
                }
            }

            Section("Shows") {
                Toggle(isOn: $tvAutoContinue) {
                    Text("Play Next Episode")
                    Text("Start the next episode when one ends.")
                }
            }

            Section("Music") {
                // Off and In Order both finish the album or playlist in order
                // (see AppState.autoContinueItem); the raw values are kept so
                // saved settings still decode.
                Picker(selection: $musicAutoContinue) {
                    Text("Finish Album").tag(MusicAutoContinue.off.rawValue)
                    Text("In Order").tag(MusicAutoContinue.inSequence.rawValue)
                    Text("Shuffle by Artist").tag(MusicAutoContinue.shuffleByGenre.rawValue)
                } label: {
                    Text("When a Song Ends")
                    Text("Keep playing the album or playlist in order, or random songs by the same artist.")
                }
            }

            Section("Continue Watching") {
                Picker(selection: $continueMusic) {
                    Text("By Album or Playlist").tag(ContinueMusicGrouping.byAlbumPlaylist.rawValue)
                    Text("By Song").tag(ContinueMusicGrouping.bySong.rawValue)
                } label: {
                    Text("Group Music")
                    Text("Show unfinished songs individually, or as their album or playlist.")
                }
                Picker(selection: $continueTimeout) {
                    ForEach(ContinueTimeout.allCases, id: \.rawValue) { timeout in
                        Text(timeout.title).tag(timeout.rawValue)
                    }
                } label: {
                    Text("Keep Items For")
                    Text("How long something you haven't finished stays in Continue Watching.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Playback") {
    PlaybackSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
