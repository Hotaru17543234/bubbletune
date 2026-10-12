import Foundation
import AVFoundation
import Network

/// 把下载好的文件放进文稿文件夹；视频只抽出声音存成 m4a
enum MediaTools {
    enum StoreError: Swift.Error {
        case cannotExport
    }

    /// 返回存好之后相对于文稿文件夹的文件名
    static func store(source: URL, originalName: String, extractAudio: Bool) async throws -> String {
        let fm = FileManager.default
        if extractAudio {
            let stem = (originalName as NSString).deletingPathExtension
            let dest = uniqueDestination(for: stem + ".m4a")
            // AVFoundation 靠扩展名认格式，先给下载好的视频一个带扩展名的临时副本
            let ext = (originalName as NSString).pathExtension.isEmpty ? "mp4" : (originalName as NSString).pathExtension
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try fm.copyItem(at: source, to: temp)
            defer { try? fm.removeItem(at: temp) }

            let asset = AVURLAsset(url: temp)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw StoreError.cannotExport
            }
            try await session.export(to: dest, as: .m4a)
            return dest.lastPathComponent
        } else {
            let dest = uniqueDestination(for: originalName)
            try fm.copyItem(at: source, to: dest)
            return dest.lastPathComponent
        }
    }

    /// 重名时变成「名字 (2).mp3」
    static func uniqueDestination(for name: String) -> URL {
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

    /// 文件名里不能有的字符换掉，太长的截短
    static func safeFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\", "\n", "\r", "\t"] {
            name = name.replacingOccurrences(of: bad, with: "_")
        }
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let stem = String((name as NSString).deletingPathExtension.prefix(110))
            name = ext.isEmpty ? stem : stem + "." + ext
        }
        return name
    }
}

/// 盯着网络：现在是不是在 Wi-Fi 上（手机流量、个人热点都算「不是」）
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "BubbleTune.network")
    private let lock = NSLock()
    private var _onWiFi = false
    private var hasUpdate = false

    /// 网络变化时在主线程回调（参数：是否在 Wi-Fi）
    var onChange: (@MainActor (Bool) -> Void)?

    var onWiFi: Bool {
        lock.lock()
        let known = hasUpdate
        let value = _onWiFi
        lock.unlock()
        if known { return value }
        // 刚启动、还没收到第一次网络通知时，直接看一眼现在的网络
        let path = monitor.currentPath
        return path.status == .satisfied && !path.isExpensive
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.status == .satisfied && !path.isExpensive
            self.lock.lock()
            let changed = wifi != self._onWiFi || !self.hasUpdate
            self._onWiFi = wifi
            self.hasUpdate = true
            self.lock.unlock()
            if changed {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.onChange?(wifi)
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }
}
