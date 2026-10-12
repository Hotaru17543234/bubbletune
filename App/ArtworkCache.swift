import UIKit

/// 歌曲封面：第一次用到时从音频文件里读出来，缩小后存在内存里
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private var images: [UUID: UIImage] = [:]
    private var missing: Set<UUID> = []

    func image(for song: Song) async -> UIImage? {
        if let cached = images[song.id] { return cached }
        if missing.contains(song.id) { return nil }
        guard let data = await SongMetadata.artworkData(url: song.url),
              let full = UIImage(data: data) else {
            missing.insert(song.id)
            return nil
        }
        let small = await Self.shrink(full, maxSide: 600)
        images[song.id] = small
        return small
    }

    func forget(_ ids: Set<UUID>) {
        for id in ids {
            images[id] = nil
            missing.remove(id)
        }
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
