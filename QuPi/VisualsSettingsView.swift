import SwiftUI

/// Appearance, the optional Playlists/Continue Watching sections, navigation (what
/// shows and music list at their top level) and sorting.
struct VisualsSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("carouselVisibleCount") private var visibleCount = 3
    @AppStorage(SettingsKeys.tvTopLevel) private var tvTopLevel = TVTopLevel.series.rawValue
    @AppStorage(SettingsKeys.musicTopLevel) private var musicTopLevel = MusicTopLevel.album.rawValue
    @AppStorage(SettingsKeys.sectionEnabled(.playlists)) private var sectionPlaylists = false
    @AppStorage(SettingsKeys.sectionEnabled(.continueItems)) private var sectionContinue = true
    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false
    @AppStorage(SettingsKeys.richMedia) private var richMedia = false
    @AppStorage(SettingsKeys.playerUISize) private var playerUISize = PlayerUISize.medium.rawValue
    @AppStorage(SettingsKeys.playerMode) private var playerMode = PlayerMode.popout.rawValue
    var body: some View {
        @Bindable var appState = appState
        Form {
            Section("Menu") {
                Picker(selection: $visibleCount) {
                    ForEach(3...6, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                } label: {
                    Text("Posters per Row")
                    Text("How many posters fit across each section at once.")
                }
                Toggle(isOn: $simpleVisuals) {
                    Text("Simple Visuals")
                    Text("Show compact text boxes instead of artwork.")
                }
                Toggle(isOn: $richMedia) {
                    Text("Info Buttons")
                    Text("Add a button to posters that shows descriptions, bios and synopses.")
                }
            }

            Section("Player") {
                Picker("Control Size", selection: $playerUISize) {
                    ForEach(PlayerUISize.allCases, id: \.rawValue) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                Picker(selection: $playerMode) {
                    ForEach(PlayerMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                } label: {
                    Text("Music Player")
                    Text("Play music inside the menu, or in its own window.")
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(isOn: $sectionContinue) {
                    Text("Continue Watching")
                    Text("What you're in the middle of, in Plex and in QuPi.")
                }
                Toggle(isOn: $sectionPlaylists) {
                    Text("Playlists")
                    Text("Your Plex and Jellyfin playlists.")
                }
            } header: {
                Text("Sections")
            } footer: {
                Text("Every server library gets its own section. Choose which ones appear, and their order, in Libraries.")
                    .foregroundStyle(.secondary)
            }

            Section("Navigation") {
                Picker(selection: $tvTopLevel) {
                    Text("Series").tag(TVTopLevel.series.rawValue)
                    Text("Season").tag(TVTopLevel.season.rawValue)
                } label: {
                    Text("Shows Start At")
                    Text("Series open into seasons, then episodes. Season lists every season directly.")
                }
                .pickerStyle(.segmented)
                Picker(selection: $musicTopLevel) {
                    Text("Artist").tag(MusicTopLevel.artist.rawValue)
                    Text("Album").tag(MusicTopLevel.album.rawValue)
                } label: {
                    Text("Music Starts At")
                    Text("Artists open into albums, then songs. Album lists every album directly.")
                }
                .pickerStyle(.segmented)
            }

            sortSection("Movie Sorting", type: .movies, sort: $appState.movieSortRaw,
                        direction: $appState.movieSortDirectionRaw, localFirst: $appState.movieLocalFirst)
            sortSection("Show Sorting", type: .tvShows, sort: $appState.tvSortRaw,
                        direction: $appState.tvSortDirectionRaw, localFirst: $appState.tvLocalFirst)
            sortSection("Music Sorting", type: .music, sort: $appState.musicSortRaw,
                        direction: $appState.musicSortDirectionRaw, localFirst: $appState.musicLocalFirst)
        }
        .formStyle(.grouped)
        .onChange(of: tvTopLevel) { appState.resetCatalog() }
        .onChange(of: musicTopLevel) { appState.resetCatalog() }
    }

    /// Sort field, order and Downloaded First for one media type. Order
    /// labels follow the field ("Newest First" for dates, "A to Z" for titles).
    private func sortSection(_ title: String, type: MediaType, sort: Binding<String>,
                             direction: Binding<String>, localFirst: Binding<Bool>) -> some View {
        let labels = (LibrarySort(rawValue: sort.wrappedValue) ?? .byTitle).directionTitles
        return Section(title) {
            Picker("Sort By", selection: sort) {
                ForEach(LibrarySort.options(for: type), id: \.self) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            Picker("Order", selection: direction) {
                Text(labels.ascending).tag(SortDirection.ascending.rawValue)
                Text(labels.descending).tag(SortDirection.descending.rawValue)
            }
            Toggle(isOn: localFirst) {
                Text("Downloaded First")
                Text("Put downloaded and local files before everything else.")
            }
        }
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Visuals") {
    VisualsSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
