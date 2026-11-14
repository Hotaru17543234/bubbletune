import Foundation
import AVFoundation

/// 打开音频文件前的两道保险
enum AudioFileSupport {
    // MARK: - 1. 只让 AVAudioFile 碰靠得住的编码

    /// AVAudioFile 碰到某些编码（比如 m4a 里装的是 Opus）会抛 Objective-C 异常，
    /// Swift 接不住，整个 app 会闪退。所以只让它处理这些常见编码，别的交给 AVAssetReader / AVAudioPlayer
    static let reliableFormats: Set<AudioFormatID> = [
        kAudioFormatLinearPCM,
        kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3,
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
        kAudioFormatMPEG4AAC_ELD_V2,
        kAudioFormatAppleLossless, kAudioFormatFLAC,
        kAudioFormatAppleIMA4, kAudioFormatULaw, kAudioFormatALaw,
    ]

    static func isReliable(_ file: AVAudioFile) -> Bool {
        reliableFormats.contains(file.fileFormat.streamDescription.pointee.mFormatID)
    }

    // MARK: - 2. 扩展名不对的文件，换个对的名字再打开

    /// 苹果的解码器很看扩展名：比如其实是 AAC 的文件叫 .mp3，就打不开。
    /// 看一眼文件开头几个字节认出真正的格式；和扩展名对不上时，
    /// 在临时文件夹里做一个带正确扩展名的「替身」（符号链接，不占空间、不改原文件），用它来打开
    static func openableURL(for url: URL) -> URL {
        guard let real = sniffExtension(url) else { return url }
        let current = url.pathExtension.lowercased()
        guard family(of: real) != family(of: current) else { return url }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("RenamedAudio", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // 同一个文件每次用同一个替身名字（FNV-1a 哈希，每次打开 app 都一样）
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        let key = String(hash, radix: 36)
        let link = folder.appendingPathComponent(key).appendingPathExtension(real)
        if (try? link.checkResourceIsReachable()) != true || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != url.path {
            try? fm.removeItem(at: link)
            guard (try? fm.createSymbolicLink(at: link, withDestinationURL: url)) != nil else { return url }
        }
        return link
    }

    /// 同一类格式的扩展名算一样（.m4a 和 .mp4 都是 MP4 封装）
    private static func family(of ext: String) -> String {
        switch ext {
        case "m4a", "mp4", "m4b", "m4v", "mov", "3gp": return "mp4"
        case "aif", "aiff", "aifc": return "aiff"
        case "aac", "adts": return "adts"
        default: return ext
        }
    }

    /// 看文件头认格式，返回该用的扩展名；认不出来返回 nil（就照原样打开）
    static func sniffExtension(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 12 else { return nil }
        let b = [UInt8](head)

        func ascii(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            guard offset + bytes.count <= b.count else { return false }
            return Array(b[offset..<offset + bytes.count]) == bytes
        }

        if ascii(4, "ftyp") { return "m4a" }
        if ascii(0, "fLaC") { return "flac" }
        if ascii(0, "RIFF") && ascii(8, "WAVE") { return "wav" }
        if ascii(0, "FORM") && (ascii(8, "AIFF") || ascii(8, "AIFC")) { return "aiff" }
        if ascii(0, "caff") { return "caf" }
        if ascii(0, "OggS") { return "ogg" }

        // MP3 / ADTS(AAC) 都以 0xFF 同步字开头；前面可能有一段 ID3 标签，跳过去再看
        var offset: UInt64 = 0
        if ascii(0, "ID3") {
            let size = (UInt64(b[6] & 0x7F) << 21) | (UInt64(b[7] & 0x7F) << 14)
                | (UInt64(b[8] & 0x7F) << 7) | UInt64(b[9] & 0x7F)
            offset = 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0)
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let frame = try? handle.read(upToCount: 4), frame.count >= 2 else {
            return offset > 0 ? "mp3" : nil
        }
        let f = [UInt8](frame)
        guard f[0] == 0xFF else { return offset > 0 ? "mp3" : nil }
        if (f[1] & 0xF6) == 0xF0 { return "aac" }                       // ADTS：12 位同步 + layer 00
        if (f[1] & 0xE0) == 0xE0 && ((f[1] >> 1) & 0x03) != 0 { return "mp3" } // MPEG 音频 layer 1/2/3
        return nil
    }
}
