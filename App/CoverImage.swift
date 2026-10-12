import UIKit
import ImageIO

/// 把相册里选的照片变成正方形封面
enum CoverImage {
    /// 读入照片 → 按拍摄方向摆正 → 取中间的正方形 → 缩到最大 1000×1000 → 存成 JPEG。
    /// 在后台做，不卡界面；照片读不出来就返回 nil
    static func squareJPEG(from data: Data, maxSide: Int = 1000) async -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        // 先缩小再处理：4800 万像素的照片直接解码会占 200 多 MB 内存
        // 长边缩到 maxSide 的 2 倍，这样裁成正方形后短边通常还够 maxSide
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 按照片里记录的方向摆正
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        // 取中间的正方形
        let side = min(image.width, image.height)
        guard side > 0 else { return nil }
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { return nil }

        // 缩到最终大小并存成 JPEG
        let target = CGFloat(min(side, maxSide))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
        let jpeg = renderer.jpegData(withCompressionQuality: 0.85) { _ in
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: target, height: target))
        }
        return jpeg
    }
}
