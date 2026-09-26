import SwiftUI

/// Navigation (what the TV/Music sections list at their top level) and
/// Playback (what continues automatically when something finishes).
struct VisualsSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("carouselVisibleCount") private var visibleCount = 3
    @AppStorage(SettingsKeys.tvTopLevel) private var tvTopLevel = TVTopLevel.series.rawValue
    @AppStorage(SettingsKeys.musicTopLevel) private var musicTopLevel = MusicTopLevel.album.rawValue
    @AppStorage("sectionEnabled_movies") private var sectionMovies = true
    @AppStorage("sectionEnabled_tvShows") private var sectionTVShows = true
    @AppStorage("sectionEnabled_music") private var sectionMusic = true
    @AppStorage("sectionEnabled_playlists") private var sectionPlaylists = false
    @AppStorage("sectionEnabled_continueItems") private var sectionContinue = false
    @AppStorage(SettingsKeys.simpleVisuals) private var simpleVisuals = false
    @AppStorage(SettingsKeys.richMedia) private var richMedia = false
    @AppStorage(SettingsKeys.continueTimeout) private var continueTimeout = ContinueTimeout.forever.rawValue
    @AppStorage(SettingsKeys.playerUISize) private var playerUISize = PlayerUISize.medium.rawValue
    @AppStorage(SettingsKeys.playerMode) private var playerMode = PlayerMode.popout.rawValue
    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                Picker("Carousel Items", selection: $visibleCount) {
                    ForEach(3...6, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Toggle("Simple Visuals", isOn: $simpleVisuals)
                Toggle("Rich Media (Descriptions, Bios and more)", isOn: $richMedia)
                Picker("Player UI Size", selection: $playerUISize) {
                    ForEach(PlayerUISize.allCases, id: \.rawValue) { size in
                        Text(size.title).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Music Player", selection: $playerMode) {
                    ForEach(PlayerMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                SectionInfoHeader(title: "Appearance", info: "Simple Visuals skips artwork entirely and shows compact text boxes instead. Rich Media adds an info button (bottom-left of posters) that shows descriptions, bios, and synopses on demand — hover tooltips will no longer show them automatically. Player UI Size scales player controls. Music Player switches between Inline or Popout.")
            }

            Section {
                Toggle("Movies", isOn: $sectionMovies)
                Toggle("TV Shows", isOn: $sectionTVShows)
                Toggle("Music", isOn: $sectionMusic)
                Toggle("Playlists", isOn: $sectionPlaylists)
                Toggle("Continue…", isOn: $sectionContinue)
            } header: {
                SectionInfoHeader(title: "Sections", info: "Playlists shows your Plex/Jellyfin playlists. Continue… lists anything you stopped partway through, and resumes it where you left off.")
            }

            Section {
                Picker("TV Top Level", selection: $tvTopLevel) {
                    Text("Series").tag(TVTopLevel.series.rawValue)
                    Text("Season").tag(TVTopLevel.season.rawValue)
                }
                .pickerStyle(.segmented)
                Picker("Music Top Level", selection: $musicTopLevel) {
                    Text("Artist").tag(MusicTopLevel.artist.rawValue)
                    Text("Album").tag(MusicTopLevel.album.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                SectionInfoHeader(title: "Navigation", info: "Series lists shows that drill into seasons, then episodes; Season lists every season directly. Artist lists artists that drill into albums, then tracks; Album lists albums directly.")
            }
            Section {
                LabeledContent("Movies") {
                    HStack {
                        Picker("", selection: $appState.movieSortRaw) {
                            Text("Title").tag(MovieSort.byTitle.rawValue)
                            Text("Year").tag(MovieSort.byYear.rawValue)
                            Text("Date Added").tag(MovieSort.byDateAdded.rawValue)
                            Text("Plays").tag(MovieSort.byPlays.rawValue)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Toggle("Local First", isOn: $appState.movieLocalFirst)
                    }
                }
                HStack {
                    Spacer()
                    Picker("", selection: $appState.movieSortDirectionRaw) {
                        Text("A -> Z").tag(SortDirection.ascending.rawValue)
                        Text("Z -> A").tag(SortDirection.descending.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("TV Shows") {
                    HStack {
                        Picker("", selection: $appState.tvSortRaw) {
                            Text("Title").tag(TVSort.byTitle.rawValue)
                            Text("Year").tag(TVSort.byYear.rawValue)
                            Text("Date Added").tag(TVSort.byDateAdded.rawValue)
                            Text("Plays").tag(TVSort.byPlays.rawValue)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Toggle("Local First", isOn: $appState.tvLocalFirst)
                    }
                }
                HStack {
                    Spacer()
                    Picker("", selection: $appState.tvSortDirectionRaw) {
                        Text("A -> Z").tag(SortDirection.ascending.rawValue)
                        Text("Z -> A").tag(SortDirection.descending.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("Music") {
                    HStack {
                        Picker("", selection: $appState.musicSortRaw) {
                            Text("Artist").tag(MusicSort.byArtist.rawValue)
                            Text("Title").tag(MusicSort.byTitle.rawValue)
                            Text("Year").tag(MusicSort.byYear.rawValue)
                            Text("Date Added").tag(MusicSort.byDateAdded.rawValue)
                            Text("Plays").tag(MusicSort.byPlays.rawValue)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Toggle("Local First", isOn: $appState.musicLocalFirst)
                    }
                }
                HStack {
                    Spacer()
                    Picker("", selection: $appState.musicSortDirectionRaw) {
                        Text("A -> Z").tag(SortDirection.ascending.rawValue)
                        Text("Z -> A").tag(SortDirection.descending.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                SectionInfoHeader(title: "Sorting", info: "Choose how each section is ordered. Date Added and Plays require server data and may not be available for all items. Local First floats downloaded and converted files to the front of the list.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: tvTopLevel) { appState.resetCatalog() }
        .onChange(of: musicTopLevel) { appState.resetCatalog() }
    }
}

#if !SWIFT_PACKAGE // Previews need Xcode; SwiftPM builds skip them.
#Preview("Visuals") {
    VisualsSettingsView()
        .environment(AppState())
        .frame(width: 520, height: 560)
}
#endif
