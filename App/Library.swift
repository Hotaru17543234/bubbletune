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

    func delete(ids: Set<UUID>) {
        for song in songs where ids.contains(song.id) {
            try? FileManager.default.removeItem(at: song.url)
        }
        songs.removeAll { ids.contains($0.id) }
        ArtworkCache.shared.forget(ids)
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var list = songs
        list.move(fromOffsets: offsets, toOffset: destination)
        songs = list
        save()
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
