import Foundation
import AVFoundation

/// 「每首歌一样响」用到的计算。
///
/// 做法：导入或同步一首歌之后，先在后台把整首歌「听」一遍（只读文件，不改文件），
/// 按 ITU-R BS.1770 / EBU R128 算出它的整体响度（LUFS，越接近 0 越响）和最响的那个采样点。
/// 播放时再根据这两个数决定调大还是调小几 dB。
/// Tests/loudness_model.py 是这个文件的一比一 Python 版，和 ffmpeg 对过答案。
enum Loudness {
    /// 算法改了就加 1，旧的结果会自动重新测一遍
    static let version = 1

    static let maxBoost = 12.0
    static let maxCut = 20.0

    /// 播放时要调大（正数）或调小（负数）几 dB。没测出来就不动
    static func gainDB(loudness: Double?, peakDB: Double?, mode: LoudnessMode) -> Double {
        gainDB(loudness: loudness, peakDB: peakDB, target: mode.target, limiterAllowance: mode.limiterAllowance)
    }

    /// limiterAllowance：调大时，最响的那一下最多让防破音压低几 dB（压太多会听出声音被「挤扁」）
    static func gainDB(loudness: Double?, peakDB: Double?, target: Double, limiterAllowance: Double) -> Double {
        guard let loudness, loudness.isFinite else { return 0 }
        var g = target - loudness
        if g > 0 {
            let headroom = -(peakDB ?? 0)
            g = min(g, max(0, headroom) + limiterAllowance)
        }
        return max(-maxCut, min(maxBoost, g))
    }

    /// 「调大 3.2 dB」「调小 4.0 dB」「不用调」
    static func describeGain(_ g: Double) -> String {
        if abs(g) < 0.05 { return "不用调" }
        return g > 0 ? String(format: "调大 %.1f dB", g) : String(format: "调小 %.1f dB", -g)
    }
}

/// 设置里的两档音量
enum LoudnessMode: String, CaseIterable, Sendable {
    /// 和 Spotify、YouTube 一样
    case standard
    /// 比标准响 4 dB，水声大的时候用；为了响，允许防破音多压一点
    case loud

    var target: Double {
        switch self {
        case .standard: return -14
        case .loud: return -10
        }
    }

    var limiterAllowance: Double {
        switch self {
        case .standard: return 4
        case .loud: return 6
        }
    }
}

/// 一首歌的测量结果
struct LoudnessResult: Sendable, Equatable {
    /// 整体响度（LUFS）。整首歌几乎没声音、或者短于 0.4 秒时是 nil
    var integrated: Double?
    /// 最响的采样点（dBFS，0 = 满格）
    var peakDB: Double?
}

/// BS.1770 响度计：一段一段喂样本进去，最后算整体响度。不依赖 AVFoundation，方便测试
struct LoudnessMeter {
    let sampleRate: Double
    let channels: Int

    private let weights: [Double]
    /// 两个二阶滤波器的系数：[b0, b1, b2, a1, a2]
    private let shelf: [Double]
    private let highpass: [Double]
    /// 每个声道两个滤波器各两个状态值
    private var state: [Double]
    /// 100 毫秒一小段
    private let step: Int
    private var subSum = 0.0
    private var subCount = 0
    private var subBlocks: [Double] = []
    private var peak: Float = 0
    /// 一共喂进来多少帧
    private(set) var frames = 0

    var seconds: Double { Double(frames) / sampleRate }

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        weights = Self.channelWeights(self.channels)
        (shelf, highpass) = Self.kWeighting(sampleRate: sampleRate)
        state = Array(repeating: 0, count: self.channels * 4)
        step = max(1, Int((0.1 * sampleRate).rounded()))
        subBlocks.reserveCapacity(4096)
    }

    /// 单声道当成左右两边放一样的声音（播放时两个喇叭都会响），所以权重是 2
    static func channelWeights(_ channels: Int) -> [Double] {
        if channels == 1 { return [2] }
        if channels == 2 { return [1, 1] }
        return (0..<channels).map { ch in
            if channels == 6 && ch == 3 { return 0 }    // 5.1 的低音声道不算
            return ch < 3 ? 1 : 1.41                    // 环绕声道
        }
    }

    /// K 计权滤波器系数（和 libebur128 用一样的公式，任何采样率都能算）
    static func kWeighting(sampleRate rate: Double) -> ([Double], [Double]) {
        var f0 = 1681.974450955533
        let G = 3.999843853973347
        var Q = 0.7071752369554196
        var K = tan(Double.pi * f0 / rate)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1.0 + K / Q + K * K
        let shelf = [
            (Vh + Vb * K / Q + K * K) / a0,
            2.0 * (K * K - Vh) / a0,
            (Vh - Vb * K / Q + K * K) / a0,
            2.0 * (K * K - 1.0) / a0,
            (1.0 - K / Q + K * K) / a0,
        ]
        f0 = 38.13547087602444
        Q = 0.5003270373238773
        K = tan(Double.pi * f0 / rate)
        let d = 1.0 + K / Q + K * K
        let highpass = [1.0, -2.0, 1.0, 2.0 * (K * K - 1.0) / d, (1.0 - K / Q + K * K) / d]
        return (shelf, highpass)
    }

    /// 喂一段样本：data[声道][第几个]，每个声道 frames 个
    mutating func process(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard frames > 0 else { return }
        let s0 = shelf[0], s1 = shelf[1], s2 = shelf[2], s3 = shelf[3], s4 = shelf[4]
        let h0 = highpass[0], h1 = highpass[1], h2 = highpass[2], h3 = highpass[3], h4 = highpass[4]
        let chCount = channels
        let step = self.step
        var subSum = self.subSum
        var subCount = self.subCount
        var peak = self.peak

        weights.withUnsafeBufferPointer { w in
            state.withUnsafeMutableBufferPointer { st in
                for i in 0..<frames {
                    var frameSum = 0.0
                    for ch in 0..<chCount {
                        let sample = data[ch][i]
                        let mag = abs(sample)
                        if mag > peak { peak = mag }
                        let weight = w[ch]
                        if weight == 0 { continue }
                        let base = ch * 4
                        // 第一个滤波器（高频搁架），Direct Form II transposed
                        let x = Double(sample)
                        let y1 = s0 * x + st[base]
                        st[base] = s1 * x - s3 * y1 + st[base + 1]
                        st[base + 1] = s2 * x - s4 * y1
                        // 第二个滤波器（高通）
                        let y2 = h0 * y1 + st[base + 2]
                        st[base + 2] = h1 * y1 - h3 * y2 + st[base + 3]
                        st[base + 3] = h2 * y1 - h4 * y2
                        frameSum += weight * y2 * y2
                    }
                    subSum += frameSum
                    subCount += 1
                    if subCount == step {
                        subBlocks.append(subSum)
                        subSum = 0
                        subCount = 0
                    }
                }
            }
        }
        self.subSum = subSum
        self.subCount = subCount
        self.peak = peak
        self.frames += frames
    }

    /// 最后结果。不满 100 毫秒的尾巴不算（和 libebur128 一样）
    func result() -> LoudnessResult {
        let peakDB: Double? = peak > 0 ? 20 * log10(Double(peak)) : nil
        guard subBlocks.count >= 4 else { return LoudnessResult(integrated: nil, peakDB: peakDB) }
        let denom = 4.0 * Double(step)
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count - 3)
        for j in 0...(subBlocks.count - 4) {
            blocks.append((subBlocks[j] + subBlocks[j + 1] + subBlocks[j + 2] + subBlocks[j + 3]) / denom)
        }
        return LoudnessResult(integrated: Self.integrate(blocks), peakDB: peakDB)
    }

    /// 400 毫秒块的均方值 → 整体响度：先去掉低于 -70 的，再去掉比平均低 10 LU 以上的
    static func integrate(_ blocks: [Double]) -> Double? {
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let aboveAbsolute = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relative = lufs(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { lufs($0) > relative }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

enum LoudnessAnalyzer {
    enum Failure: Swift.Error {
        case badFormat
        case noBuffer
        case noAudioTrack
        case noAudio
    }

    /// 两种读法都失败时的错误，记着各自的原因，方便在设置里显示
    struct BothFailed: Swift.Error {
        let audioFile: Swift.Error
        let assetReader: Swift.Error
    }

    /// 是用哪种方法测出来的（检查程序里看）
    enum Method: String, Sendable {
        case audioFile = "AVAudioFile"
        case audioFilePartial = "AVAudioFile(后面坏了，只用前面)"
        case assetReader = "AVAssetReader"
        case assetReaderPartial = "AVAssetReader(后面坏了，只用前面)"
    }

    struct Measurement: Sendable {
        var result: LoudnessResult
        var method: Method
    }

    /// 读整首歌测响度。比较花时间（一首歌不到一秒），别在主线程上调
    static func analyze(url: URL) async throws -> LoudnessResult {
        try await measure(url: url).result
    }

    /// 先用 AVAudioFile 读（快）；打不开、或者一开头就读不下去，
    /// 再用 AVAssetReader 读（和系统播视频用的是同一套解码，带画面的 mp4、奇怪的封装也能读）
    static func measure(url original: URL) async throws -> Measurement {
        // 扩展名不对的文件（比如其实是 AAC 却叫 .mp3），换个对的名字再打开
        let url = AudioFileSupport.openableURL(for: original)
        let firstError: Swift.Error
        do {
            return try measureWithAudioFile(url)
        } catch {
            firstError = error
        }
        do {
            return try await measureWithAssetReader(url)
        } catch {
            throw BothFailed(audioFile: firstError, assetReader: error)
        }
    }

    /// 文件只是后面一小段坏了：前面读到的够多（至少 5 秒，而且过了一半）就用前面的
    private static func enoughBeforeError(_ meter: LoudnessMeter, expectedFrames: Double) -> Bool {
        meter.seconds >= 5 && (expectedFrames <= 0 || Double(meter.frames) >= 0.5 * expectedFrames)
    }

    static func measureWithAudioFile(_ url: URL) throws -> Measurement {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        // 不常见的编码交给 AVAssetReader（AVAudioFile 碰它们可能直接闪退）
        guard AudioFileSupport.isReliable(file) else { throw Failure.badFormat }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { throw Failure.badFormat }

        var meter = LoudnessMeter(sampleRate: format.sampleRate, channels: channels)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.noBuffer
        }
        var partial = false
        let expected = file.length
        while AVAudioFramePosition(meter.frames) < expected {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                guard enoughBeforeError(meter, expectedFrames: Double(expected)) else { throw error }
                partial = true
                break
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw Failure.noBuffer }
            meter.process(UnsafePointer(data), frames: n)
        }
        // 打开了却一帧都读不出来，当成失败，换另一种读法
        guard meter.frames > 0 else { throw Failure.noAudio }
        return Measurement(result: meter.result(), method: partial ? .audioFilePartial : .audioFile)
    }

    static func measureWithAssetReader(_ url: URL) async throws -> Measurement {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }
        let expectedSeconds = (try? await asset.load(.duration))?.seconds ?? 0

        let reader = try AVAssetReader(asset: asset)
        // 解码成 32 位浮点、交错排列（左右左右……），采样率和声道数保持原样
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.badFormat }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.badFormat }

        var meter: LoudnessMeter?
        var channels = 0
        var interleaved: [Float] = []
        var planar: [UnsafeMutablePointer<Float>] = []
        var capacity = 0
        defer { planar.forEach { $0.deallocate() } }

        while let sample = output.copyNextSampleBuffer() {
            if meter == nil {
                guard let desc = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                      asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else { continue }
                channels = Int(asbd.mChannelsPerFrame)
                meter = LoudnessMeter(sampleRate: asbd.mSampleRate, channels: channels)
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            let frames = count / channels
            guard frames > 0 else { continue }
            if interleaved.count < count {
                interleaved = [Float](repeating: 0, count: count)
            }
            let status = interleaved.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            // 拆成一个声道一条，交给响度计
            if frames > capacity {
                planar.forEach { $0.deallocate() }
                planar = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
                capacity = frames
            }
            interleaved.withUnsafeBufferPointer { src in
                for ch in 0..<channels {
                    let dst = planar[ch]
                    var j = ch
                    for i in 0..<frames {
                        dst[i] = src[j]
                        j += channels
                    }
                }
            }
            planar.withUnsafeBufferPointer { ptrs in
                meter!.process(ptrs.baseAddress!, frames: frames)
            }
        }

        guard let meter, meter.frames > 0 else {
            throw reader.error ?? Failure.noAudio
        }
        if reader.status == .failed {
            let expectedFrames = expectedSeconds.isFinite ? expectedSeconds * meter.sampleRate : 0
            guard enoughBeforeError(meter, expectedFrames: expectedFrames) else {
                throw reader.error ?? Failure.noAudio
            }
            return Measurement(result: meter.result(), method: .assetReaderPartial)
        }
        return Measurement(result: meter.result(), method: .assetReader)
    }

    /// 给人看的失败原因（设置里「读不了的歌」那一页用）
    static func describe(_ error: Swift.Error) -> String {
        if let both = error as? BothFailed {
            return "方法一：\(shortCode(both.audioFile))；方法二：\(shortCode(both.assetReader))"
        }
        return shortCode(error)
    }

    private static func shortCode(_ error: Swift.Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .badFormat: return "格式不对"
            case .noBuffer: return "内存不够"
            case .noAudioTrack: return "里面没有声音"
            case .noAudio: return "一帧都读不出来"
            }
        }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        // Core Audio 的错误码常常是四个字母（比如 'typ?' = 不认识的文件类型）
        let code = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            text += " '" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return text
    }
}
