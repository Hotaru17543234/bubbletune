import UIKit

/// 歌曲封面：第一次用到时读出来（自定义封面优先，没有就读音乐文件自带的），缩小后存在内存里
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    /// 用 Song.artworkKey 当钥匙：换了封面钥匙就变，不会拿到旧图
    private var images: [String: UIImage] = [:]
    private var missing: Set<String> = []

    func image(for song: Song) async -> UIImage? {
        let key = song.artworkKey
        if let cached = images[key] { return cached }
        if missing.contains(key) { return nil }

        let data: Data?
        if let file = song.customArtworkFile {
            data = await Self.readFile(Storage.coverURL(file))
        } else {
            data = await SongMetadata.artworkData(url: song.url)
        }
        guard let data, let full = UIImage(data: data) else {
            missing.insert(key)
            return nil
        }
        let small = await Self.shrink(full, maxSide: 600)
        images[key] = small
        return small
    }

    /// 忘掉这些歌的所有封面缓存（删除歌曲、改封面时用）
    func forget(_ ids: Set<UUID>) {
        let prefixes = ids.map { $0.uuidString + "|" }
        images = images.filter { key, _ in !prefixes.contains { key.hasPrefix($0) } }
        missing = missing.filter { key in !prefixes.contains { key.hasPrefix($0) } }
    }

    nonisolated private static func readFile(_ url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }

    nonisolated private static func shrink(_ image: UIImage, maxSide: CGFloat) async -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        return await image.byPreparingThumbnail(ofSize: target) ?? image
    }
}
