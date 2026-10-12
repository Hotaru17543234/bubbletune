import SwiftUI
import PhotosUI

/// 编辑一首歌的封面、歌名、歌手、专辑（只改泡泡音里的显示，不动音乐文件）
struct SongEditorView: View {
    let song: Song

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var cover: Library.CoverChange = .keep
    @State private var newCoverPreview: UIImage?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var saving = false
    @State private var photoError = false

    init(song: Song) {
        self.song = song
        _title = State(initialValue: song.displayTitle)
        _artist = State(initialValue: song.artistText)
        _album = State(initialValue: song.displayAlbum)
    }

    /// 选了「用回自带封面」时，预览要显示的样子
    private var songWithoutCustomCover: Song {
        var s = song
        s.customArtworkFile = nil
        return s
    }

    private var showsCustomCover: Bool {
        switch cover {
        case .keep: return song.customArtworkFile != nil
        case .remove: return false
        case .replace: return true
        }
    }

    private var hasChanges: Bool {
        if case .keep = cover {} else { return true }
        return title != song.displayTitle || artist != song.artistText || album != song.displayAlbum
    }

    var body: some View {
        NavigationStack {
            Form {
                coverSection
                infoSection
                if song.isEdited || hasChanges {
                    resetSection
                }
                Section {
                    LabeledContent("音乐文件", value: (song.fileName as NSString).lastPathComponent)
                        .font(.footnote)
                }
            }
            .navigationTitle("编辑歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存") { save() }
                            .fontWeight(.bold)
                            .disabled(loadingPhoto || !hasChanges)
                    }
                }
            }
            .alert("这张照片读不出来", isPresented: $photoError) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("换一张试试吧～")
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
        }
        .fontDesign(.rounded)
        .tint(Theme.blue)
        .interactiveDismissDisabled(hasChanges)
    }

    // MARK: - 封面

    private var coverSection: some View {
        Section {
            HStack {
                Spacer()
                ZStack {
                    if let preview = newCoverPreview, case .replace = cover {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    } else if case .remove = cover {
                        ArtworkView(song: songWithoutCustomCover, size: 180, cornerRadius: 26)
                    } else {
                        ArtworkView(song: song, size: 180, cornerRadius: 26)
                    }
                    if loadingPhoto {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 180, height: 180)
                        ProgressView()
                    }
                }
                .shadow(color: Theme.blue.opacity(0.2), radius: 12, y: 6)
                Spacer()
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)

            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Label("从相册选一张做封面", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(loadingPhoto)

            if showsCustomCover {
                Button {
                    cover = .remove
                    newCoverPreview = nil
                } label: {
                    Label("用回歌曲自带的封面", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("封面")
        } footer: {
            Text("不是正方形的照片会自动取中间的部分。")
        }
    }

    // MARK: - 文字信息

    private var infoSection: some View {
        Section {
            field("歌名", text: $title, original: song.title)
            field("歌手", text: $artist, original: song.artist)
            field("专辑", text: $album, original: song.album)
        } header: {
            Text("歌曲信息")
        } footer: {
            Text("只改泡泡音里的显示，不会动音乐文件本身。留空就用回原来的。")
        }
    }

    private func field(_ label: String, text: Binding<String>, original: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink.opacity(0.55))
            HStack {
                TextField(original.isEmpty ? "（原来是空的）" : original, text: text)
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                if !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.ink.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空\(label)")
                }
            }
            if !original.isEmpty && text.wrappedValue != original {
                Text("原来：\(original)")
                    .font(.caption2)
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 恢复原样

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                title = song.title
                artist = song.artist
                album = song.album
                newCoverPreview = nil
                cover = song.customArtworkFile != nil ? .remove : .keep
            } label: {
                Label("全部恢复原样", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("把歌名、歌手、专辑和封面都变回音乐文件里原来的样子，点「保存」后生效。")
        }
    }

    // MARK: - 动作

    private func loadPhoto(_ item: PhotosPickerItem) {
        loadingPhoto = true
        Task {
            var jpeg: Data?
            if let data = try? await item.loadTransferable(type: Data.self) {
                jpeg = await CoverImage.squareJPEG(from: data)
            }
            if let jpeg, let image = UIImage(data: jpeg) {
                cover = .replace(jpeg)
                newCoverPreview = image
            } else {
                photoError = true
            }
            loadingPhoto = false
            pickedPhoto = nil
        }
    }

    private func save() {
        saving = true
        Task {
            await library.updateSong(song.id, title: title, artist: artist, album: album, cover: cover)
            dismiss()
        }
    }
}
