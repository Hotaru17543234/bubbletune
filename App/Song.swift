import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// 列表里的一首歌。真正的音频文件放在 app 的「文稿」文件夹里，
/// 这个文件夹会出现在「文件」App →「我的 iPhone」→「泡泡音」。
struct Song: Identifiable, Codable, Hashable {
    var id: UUID
    /// 相对于文稿文件夹的路径，比如 "晴天.mp3"
    var fileName: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var addedAt: Date
    var metadataLoaded: Bool

    // 你在泡泡音里改过的信息（nil = 没改过，用上面从文件里读出来的）
    // 都是可选的，旧版本存下来的歌曲列表也能直接读
    var customTitle: String?
    var customArtist: String?
    var customAlbum: String?
    /// 自定义封面的文件名，放在 Application Support/Covers 里
    var customArtworkFile: String?

    // 从 Telegram 频道同步来的歌：记住来自哪个频道的哪条消息
    var tgChatID: Int64?
    var tgMessageID: Int64?

    var telegramKey: String? {
        guard let tgChatID, let tgMessageID else { return nil }
        return "\(tgChatID):\(tgMessageID)"
    }

    var url: URL {
        Storage.documents.appendingPathComponent(fileName)
    }

    /// 界面上显示的歌名 / 歌手 / 专辑：改过的优先
    var displayTitle: String { customTitle ?? title }

    var artistText: String { customArtist ?? artist }

    var displayArtist: String {
        artistText.isEmpty ? "未知歌手" : artistText
    }

    var displayAlbum: String { customAlbum ?? album }

    var isEdited: Bool {
        customTitle != nil || customArtist != nil || customAlbum != nil || customArtworkFile != nil
    }

    /// 封面换了，这个值就会变，界面靠它知道要重新读封面
    var artworkKey: String {
        id.uuidString + "|" + (customArtworkFile ?? "embedded")
    }

    /// 没有歌曲信息时，从文件名猜：「周杰伦 - 晴天.mp3」→ 歌手 周杰伦，歌名 晴天
    static func guess(fromFileName fileName: String) -> (title: String, artist: String) {
        let base = (fileName as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let parts = stem.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty {
                return (title, artist)
            }
        }
        return (stem, "")
    }
}

enum Storage {
    static let documents: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var libraryFile: URL {
        support.appendingPathComponent("library.json")
    }

    /// 自定义封面放这里（不放进文稿文件夹，免得「文件」App 里的歌曲文件夹变乱）
    static let covers: URL = {
        let url = support.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func coverURL(_ fileName: String) -> URL {
        covers.appendingPathComponent(fileName)
    }

    /// iPhone 自带解码器能放的格式
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "m4b", "mp4", "alac",
    ]

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// 导入时在「文件」里可以选的类型
    static let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in ["flac", "m4b", "caf", "aac"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }()

    /// url 如果在文稿文件夹里，返回相对路径
    static func relativePath(of url: URL) -> String? {
        let base = documents.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// 文稿文件夹里至少要有一个文件，「文件」App 才会显示这个文件夹
    static func ensureReadme() {
        let url = documents.appendingPathComponent("把歌放在这里.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        把 mp3、m4a、flac、wav 等歌曲文件放进这个文件夹，
        再打开泡泡音，它们就会自动出现在歌曲列表里啦～

        在这里删掉歌曲文件，泡泡音的列表里也会跟着消失。
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 从音频文件里读出的歌曲信息
struct SongMetadata: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?

    static func load(url: URL) async -> SongMetadata {
        let asset = AVURLAsset(url: url)
        var meta = SongMetadata()
        if let time = try? await asset.load(.duration), time.isNumeric {
            meta.duration = time.seconds
        }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyTitle {
                    meta.title = try? await item.load(.stringValue)
                } else if key == .commonKeyArtist {
                    meta.artist = try? await item.load(.stringValue)
                } else if key == .commonKeyAlbumName {
                    meta.album = try? await item.load(.stringValue)
                }
            }
        }
        return meta
    }

    static func artworkData(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        let artworks = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
        for item in artworks {
            if let data = try? await item.load(.dataValue) {
                return data
            }
        }
        return nil
    }
}
