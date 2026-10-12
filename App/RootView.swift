import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @Environment(\.scenePhase) private var scenePhase

    @State private var search = ""
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var showShower = false
    @State private var showSettings = false
    @State private var showerAfterSheet = false
    @State private var editingSong: Song?

    private var filteredSongs: [Song] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.songs }
        return library.songs.filter { song in
            [song.displayTitle, song.artistText, song.displayAlbum, song.title, song.artist, song.fileName]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BubbleBackground()
                if library.songs.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        SearchField(text: $search)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                        songList
                    }
                }
            }
            .navigationTitle("泡泡音")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !library.songs.isEmpty {
                        EditButton()
                    }
                    Button { showImporter = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("导入歌曲")
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomPanel(openNowPlaying: { showNowPlaying = true },
                            openShower: { showShower = true })
            }
        }
        .tint(Theme.blue)
        .fontDesign(.rounded)
        .overlay(alignment: .top) {
            if let text = library.toast {
                ToastView(text: text)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if library.isImporting {
                ProgressView("正在导入…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Storage.importTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                library.importFiles(urls)
            case .failure:
                library.showToast("没能打开「文件」，再试一次吧")
            }
        }
        .sheet(isPresented: $showNowPlaying, onDismiss: {
            if showerAfterSheet {
                showerAfterSheet = false
                showShower = true
            }
        }) {
            NowPlayingView(openShowerMode: {
                showerAfterSheet = true
                showNowPlaying = false
            })
            .environmentObject(player)
            .environmentObject(library)
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingSong) { song in
            SongEditorView(song: song)
                .environmentObject(library)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(library)
        }
        .fullScreenCover(isPresented: $showShower) {
            ShowerModeView()
                .environmentObject(player)
                .environmentObject(library)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                library.scanDocuments()
            case .background:
                player.saveState()
            default:
                break
            }
        }
    }

    // MARK: - 歌曲列表

    /// 拖动排序（搜索时不能拖）
    private var moveAction: (IndexSet, Int) -> Void {
        { from, to in library.move(from: from, to: to) }
    }

    private var songList: some View {
        List {
            Section {
                ForEach(filteredSongs) { song in
                    Button {
                        player.playSong(song.id)
                    } label: {
                        SongRow(song: song,
                                isCurrent: song.id == player.currentID,
                                isPlaying: song.id == player.currentID && player.isPlaying)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        song.id == player.currentID ? Color.white.opacity(0.9) : Theme.card
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            library.delete(ids: [song.id])
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            editingSong = song
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(Theme.blue)
                    }
                    .contextMenu {
                        Button {
                            editingSong = song
                        } label: {
                            Label("编辑歌曲信息", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            library.delete(ids: [song.id])
                        } label: {
                            Label("删除这首歌", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    let list = filteredSongs
                    let ids = Set(offsets.map { list[$0].id })
                    library.delete(ids: ids)
                }
                .onMove(perform: search.isEmpty ? moveAction : nil)
            } header: {
                Text("\(library.songs.count) 首歌")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink.opacity(0.55))
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    // MARK: - 还没有歌

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 130, height: 130)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Theme.blue)
                }
                .padding(.top, 40)

                Text("还没有歌哦")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ink)

                Button {
                    showImporter = true
                } label: {
                    Label("从「文件」导入歌曲", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 14)
                        .background(Theme.blue, in: Capsule())
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 10) {
                    hint("square.and.arrow.up", "在别的 App 里点「分享」→「泡泡音」也可以")
                    hint("folder", "或者把歌放进「文件」→「我的 iPhone」→「泡泡音」")
                    hint("desktopcomputer", "电脑传歌的方法在左上角「设置」里")
                }
                .padding(18)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func hint(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.blue)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.ink.opacity(0.8))
        }
    }
}

// MARK: - 搜索框

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.ink.opacity(0.45))
            TextField("搜索歌名或歌手", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(Theme.ink)
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.ink.opacity(0.35))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1))
    }
}

// MARK: - 列表里的一行

struct SongRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(song: song, size: 46, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.displayTitle)
                    .font(.body.weight(isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? Theme.blue : Theme.ink)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .font(.caption)
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                PlayingBars(animating: isPlaying)
            } else if song.duration > 0 {
                Text(Theme.time(song.duration))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 底部播放条

struct BottomPanel: View {
    @EnvironmentObject private var player: Player
    var openNowPlaying: () -> Void
    var openShower: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // 小播放条
            HStack(spacing: 12) {
                Button(action: openNowPlaying) {
                    HStack(spacing: 12) {
                        ArtworkView(song: player.currentSong, size: 44, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentSong?.displayTitle ?? "还没有在放歌")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(player.currentSong?.displayArtist ?? "点一首歌开始吧")
                                .font(.caption)
                                .foregroundStyle(Theme.ink.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .accessibilityLabel("上一首")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 34)
                }
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .accessibilityLabel("下一首")
            }
            .foregroundStyle(Theme.blue)
            .buttonStyle(.plain)

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let total = max(player.duration, 0.1)
                let ratio = min(1, max(0, player.currentTime / total))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.blue.opacity(0.15))
                        Capsule().fill(Theme.blue)
                            .frame(width: geo.size.width * CGFloat(ratio))
                    }
                }
                .frame(height: 4)
            }
            .frame(height: 4)

            // 播放方式 + 洗澡模式
            HStack(spacing: 8) {
                Menu {
                    Picker("播放顺序", selection: Binding(get: { player.orderMode },
                                                       set: { player.setOrderMode($0) })) {
                        ForEach(OrderMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode)
                        }
                    }
                } label: {
                    chip(icon: player.orderMode.icon, text: player.orderMode.shortTitle)
                }

                Menu {
                    Picker("播完之后", selection: Binding(get: { player.repeatMode },
                                                      set: { player.setRepeatMode($0) })) {
                        ForEach(RepeatMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode)
                        }
                    }
                } label: {
                    chip(icon: player.repeatMode.icon, text: player.repeatMode.title)
                }

                Spacer(minLength: 0)

                Button(action: openShower) {
                    Label("洗澡模式", systemImage: "shower.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.blue, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: Theme.blue.opacity(0.18), radius: 14, y: 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.deepBlue)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.sky, in: Capsule())
        .overlay(Capsule().stroke(Theme.blue.opacity(0.25), lineWidth: 1))
    }
}
