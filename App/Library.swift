import Foundation
import SwiftUI

/// 歌曲列表：保存顺序、导入、删除、扫描文稿文件夹
@MainActor
final class Library: ObservableObject {
    @Published private(set) var songs: [Song] = [] {
        didSet {
            let ids = songs.map(\.id)
            if ids != oldValue.map(\.id) {
                onSongsChanged?(ids)
            }
        }
    }
    @Published private(set) var toast: String?
    @Published private(set) var isImporting = false

    /// 歌曲增减或顺序改变时通知播放器
    var onSongsChanged: (@MainActor ([UUID]) -> Void)?
    /// 某首歌的信息或封面被改了（播放器要更新锁屏上的显示）
    var onSongEdited: (@MainActor (UUID) -> Void)?
    /// 你自己删掉了歌（在泡泡音里删，或者在「文件」App 里删掉文件）。
    /// Telegram 同步用它记住「这首别再同步回来」
    var onSongsDeleted: (@MainActor ([Song]) -> Void)?

    private var loadingIDs: Set<UUID> = []
    private var toastTask: Task<Void, Never>?

    init() {
        load()
        Storage.ensureReadme()
        _ = scanDocuments()
    }

    func song(id: UUID?) -> Song? {
        guard let id else { return nil }
        return songs.first { $0.id == id }
    }

    // MARK: - 保存 / 读取

    private func load() {
        guard let data = try? Data(contentsOf: Storage.libraryFile),
              let list = try? JSONDecoder().decode([Song].self, from: data) else { return }
        songs = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        try? data.write(to: Storage.libraryFile, options: .atomic)
    }

    // MARK: - 扫描文稿文件夹

    /// 和文稿文件夹对一遍账：新出现的歌加进列表，文件没了的歌移出列表。返回新加了几首
    @discardableResult
    func scanDocuments() -> Int {
        let fm = FileManager.default
        var found: [String] = []
        if let walker = fm.enumerator(at: Storage.documents,
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let url = walker.nextObject() as? URL {
                if Storage.isAudio(url), let rel = Storage.relativePath(of: url) {
                    found.append(rel)
                }
            }
        }
        let foundSet = Set(found)
        var list = songs.filter { foundSet.contains($0.fileName) }
        let gone = songs.filter { !foundSet.contains($0.fileName) }
        for song in gone {
            if let file = song.customArtworkFile { Self.deleteCover(file) }
        }
        if !gone.isEmpty {
            ArtworkCache.shared.forget(Set(gone.map(\.id)))
            onSongsDeleted?(gone)
        }
        let known = Set(list.map(\.fileName))
        let newOnes = found
            .filter { !known.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for rel in newOnes {
            let guess = Song.guess(fromFileName: rel)
            list.append(Song(id: UUID(), fileName: rel, title: guess.title, artist: guess.artist,
                             album: "", duration: 0, addedAt: Date(), metadataLoaded: false))
        }
        if list != songs {
            songs = list
            save()
        }
        loadMissingMetadata()
        return newOnes.count
    }

    private func loadMissingMetadata() {
        for song in songs where !song.metadataLoaded && !loadingIDs.contains(song.id) {
            loadingIDs.insert(song.id)
            let id = song.id
            let url = song.url
            Task {
                let meta = await SongMetadata.load(url: url)
                self.apply(meta, to: id)
            }
        }
    }

    private func apply(_ meta: SongMetadata, to id: UUID) {
        loadingIDs.remove(id)
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        var song = songs[i]
        if let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            song.title = t
        }
        if let a = meta.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            song.artist = a
        }
        if let al = meta.album?.trimmingCharacters(in: .whitespacesAndNewlines), !al.isEmpty {
            song.album = al
        }
        if let d = meta.duration, d.isFinite, d > 0 {
            song.duration = d
        }
        song.metadataLoaded = true
        songs[i] = song
        save()
        // 刚导入就在放的歌：读到真正的歌名后，锁屏上也换掉文件名
        onSongEdited?(id)
    }

    // MARK: - 导入

    /// 从「文件」选来的、或者别的 App「用泡泡音打开」的文件
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            let result = await Self.copyIntoDocuments(urls)
            let added = self.scanDocuments()
            self.isImporting = false
            self.showToast(result.message(added: added))
        }
    }

    struct ImportResult: Sendable {
        var duplicates = 0
        var unsupported = 0
        var failed = 0

        func message(added: Int) -> String {
            var parts: [String] = []
            if added > 0 { parts.append("导入了 \(added) 首歌 🎵") }
            if duplicates > 0 { parts.append("\(duplicates) 首已经在列表里啦") }
            if unsupported > 0 { parts.append("\(unsupported) 个不是能放的音频") }
            if failed > 0 { parts.append("\(failed) 个没导进来") }
            return parts.isEmpty ? "没有新的歌哦" : parts.joined(separator: "，")
        }
    }

    /// 把文件复制进文稿文件夹（在后台做，不卡界面）
    nonisolated static func copyIntoDocuments(_ urls: [URL]) async -> ImportResult {
        var result = ImportResult()
        let fm = FileManager.default
        for url in urls {
            guard isAudio(url) else {
                result.unsupported += 1
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            // 已经在我们自己的文件夹里了（比如系统放进 Inbox 的）
            if let rel = Storage.relativePath(of: url) {
                if rel.hasPrefix("Inbox/") {
                    let dest = uniqueDestination(for: url.lastPathComponent)
                    if sameFileExists(source: url, name: url.lastPathComponent) {
                        try? fm.removeItem(at: url)
                        result.duplicates += 1
                    } else if (try? fm.moveItem(at: url, to: dest)) == nil {
                        result.failed += 1
                    }
                }
                continue
            }

            if sameFileExists(source: url, name: url.lastPathComponent) {
                result.duplicates += 1
                continue
            }
            let dest = uniqueDestination(for: url.lastPathComponent)

            // 用 NSFileCoordinator 读，这样还没下载的 iCloud 文件也会先下载下来
            var coordError: NSError?
            var copyFailed = false
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                do {
                    try fm.copyItem(at: readURL, to: dest)
                } catch {
                    copyFailed = true
                }
            }
            if coordError != nil || copyFailed {
                result.failed += 1
            }
        }
        return result
    }

    nonisolated private static func isAudio(_ url: URL) -> Bool {
        Storage.isAudio(url)
    }

    /// 文稿文件夹里已经有同名、同大小的文件 → 当成同一首歌
    nonisolated private static func sameFileExists(source: URL, name: String) -> Bool {
        let fm = FileManager.default
        let existing = Storage.documents.appendingPathComponent(name)
        guard fm.fileExists(atPath: existing.path) else { return false }
        let a = (try? fm.attributesOfItem(atPath: existing.path)[.size] as? NSNumber)?.int64Value
        let b = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
        return a != nil && a == b
    }

    /// 重名但内容不同 → 「晴天 (2).mp3」
    nonisolated private static func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = Storage.documents.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = Storage.documents.appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }

    // MARK: - 删除 / 排序

    /// byUser = false 表示是 Telegram 同步删的（频道里的消息被删了），不用记成「别再同步」
    func delete(ids: Set<UUID>, byUser: Bool = true) {
        let removed = songs.filter { ids.contains($0.id) }
        for song in songs where ids.contains(song.id) {
            try? FileManager.default.removeItem(at: song.url)
            if let file = song.customArtworkFile { Self.deleteCover(file) }
        }
        songs.removeAll { ids.contains($0.id) }
        ArtworkCache.shared.forget(ids)
        save()
        if byUser && !removed.isEmpty {
            onSongsDeleted?(removed)
        }
    }

    // MARK: - Telegram 同步用

    /// 同步下载好一首歌（文件已经放进文稿文件夹）后登记到列表里，按频道发布顺序插入
    func addSyncedSong(fileName: String, chatID: Int64, messageID: Int64) {
        // 扫描文件夹时可能已经先把这个文件加进来了，那就只补上来源
        if let i = songs.firstIndex(where: { $0.fileName == fileName }) {
            var linked = songs[i]
            linked.tgChatID = chatID
            linked.tgMessageID = messageID
            songs[i] = linked
            save()
            return
        }
        let guess = Song.guess(fromFileName: fileName)
        let newSong = Song(id: UUID(), fileName: fileName, title: guess.title, artist: guess.artist,
                           album: "", duration: 0, addedAt: Date(), metadataLoaded: false,
                           tgChatID: chatID, tgMessageID: messageID)
        // 放在同一个频道里第一首「比它晚发」的歌前面；没有就放最后
        if let j = songs.firstIndex(where: { $0.tgChatID == chatID && ($0.tgMessageID ?? 0) > messageID }) {
            songs.insert(newSong, at: j)
        } else {
            songs.append(newSong)
        }
        save()
        loadMissingMetadata()
    }

    /// 找一首「以前手动导入、还没和 Telegram 关联」的同名同大小的歌
    func unlinkedSong(matchingFileName name: String, size: Int64) -> Song? {
        let target = name.lowercased()
        return songs.first { song in
            guard song.tgMessageID == nil,
                  (song.fileName as NSString).lastPathComponent.lowercased() == target else { return false }
            let attrs = try? FileManager.default.attributesOfItem(atPath: song.url.path)
            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            return size <= 0 || bytes == size
        }
    }

    /// 把一首已有的歌和频道里的消息关联起来（不重复下载，改过的名字和封面都保留）
    func linkTelegram(songID: UUID, chatID: Int64, messageID: Int64) {
        guard let i = songs.firstIndex(where: { $0.id == songID }) else { return }
        var linked = songs[i]
        linked.tgChatID = chatID
        linked.tgMessageID = messageID
        songs[i] = linked
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var list = songs
        list.move(fromOffsets: offsets, toOffset: destination)
        songs = list
        save()
    }

    // MARK: - 编辑歌曲信息（只在泡泡音里生效，不改音乐文件）

    enum CoverChange: Sendable {
        case keep              // 封面不动
        case remove            // 去掉自定义封面，用回音乐文件自带的
        case replace(Data)     // 换成新封面（已经裁好的正方形 JPEG）
    }

    /// 保存编辑页里的修改。文字和原来一样、或者留空，就当作没改
    func updateSong(_ id: UUID, title: String, artist: String, album: String, cover: CoverChange) async {
        guard let before = song(id: id) else { return }

        var coverFile = before.customArtworkFile
        switch cover {
        case .keep:
            break
        case .remove:
            coverFile = nil
        case .replace(let jpeg):
            // 每次用新文件名，界面就知道封面换了
            let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            if await Self.writeCover(jpeg, name: name) {
                coverFile = name
            } else {
                showToast("封面没存进去，再试一次吧")
            }
        }

        // 上面等待写文件的时候列表可能变了，重新找一次
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        var edited = songs[i]
        edited.customTitle = Self.override(title, original: edited.title)
        edited.customArtist = Self.override(artist, original: edited.artist)
        edited.customAlbum = Self.override(album, original: edited.album)
        if let old = edited.customArtworkFile, old != coverFile {
            Self.deleteCover(old)
        }
        edited.customArtworkFile = coverFile
        songs[i] = edited
        save()

        ArtworkCache.shared.forget([id])
        onSongEdited?(id)
        showToast("改好啦 ✨")
    }

    /// 去掉首尾空格；留空或者和原来一样 → nil（不算修改）
    private static func override(_ text: String, original: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == original { return nil }
        return t
    }

    nonisolated private static func writeCover(_ data: Data, name: String) async -> Bool {
        do {
            try data.write(to: Storage.coverURL(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func deleteCover(_ name: String) {
        try? FileManager.default.removeItem(at: Storage.coverURL(name))
    }

    // MARK: - 小提示

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
        }
    }
}
