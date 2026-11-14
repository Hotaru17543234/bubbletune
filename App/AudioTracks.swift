import Foundation
import AVFoundation
import QuartzCore

/// 正在放的「一首歌」。Player 只跟这个打交道，不用管底下是哪种播放器
@MainActor
protocol AudioTrack: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    /// 正常放完了（被切歌、暂停、停止都不算）
    var onFinish: (() -> Void)? { get set }
    /// 自己停下来了（比如系统音频出了状况又没能恢复），让界面上的按钮跟着变
    var onUnexpectedStop: (() -> Void)? { get set }
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval)
    /// 调大 / 调小几 dB。animated = 半秒内慢慢变过去，不会「咚」一下
    func setGain(_ db: Double, animated: Bool)
}

@MainActor
enum AudioTracks {
    /// 优先用能调大音量的 EngineTrack；打不开时退回系统自带播放器（只能调小）
    static func open(url: URL, gainDB: Double) throws -> AudioTrack {
        if let track = try? EngineTrack(url: url, gainDB: gainDB) {
            return track
        }
        return try SimpleTrack(url: url, gainDB: gainDB)
    }
}

// MARK: - 声音处理链

/// 播放节点 → 小混音器（统一成立体声）→ 调音量 → 防破音 → 主混音器 → 喇叭
///
/// 单独拿出来，是为了在电脑上用「离线渲染」测试同一条链（Tests/LoudnessCheck）。
struct PlaybackChain {
    let player = AVAudioPlayerNode()
    let mixer = AVAudioMixerNode()
    let gain: AVAudioUnitEQ = {
        // 只用它的「整体增益」，唯一的频段关掉
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].bypass = true
        return eq
    }()
    let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0))

    /// 单声道的歌升成立体声时，混音器会把左右各降 3 dB（等功率），这里补回来，
    /// 让它和测响度时的假设一样：左右两边都是原来的音量
    let compensationDB: Double

    init(fileChannels: AVAudioChannelCount) {
        compensationDB = fileChannels == 1 ? 20 * log10(2.0.squareRoot()) : 0
    }

    /// 立体声、和歌曲一样的采样率：调音量和防破音都在这个格式上做
    static func stereoFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
    }

    func attach(to engine: AVAudioEngine) {
        engine.attach(player)
        engine.attach(mixer)
        engine.attach(gain)
        engine.attach(limiter)
    }

    /// fileFormat：歌曲文件解码后的格式（可能是单声道）
    func connect(in engine: AVAudioEngine, fileFormat: AVAudioFormat, stereo: AVAudioFormat) {
        engine.connect(player, to: mixer, format: fileFormat)
        engine.connect(mixer, to: gain, format: stereo)
        engine.connect(gain, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
    }

    /// 要调 db 时，EQ 上实际设的值（EQ 的整体增益范围是 -96 ～ +24 dB）
    func gainValue(_ db: Double) -> Float {
        Float(max(-60, min(24, db + compensationDB)))
    }

    func setGain(_ db: Double) {
        gain.globalGain = gainValue(db)
    }
}

// MARK: - 能调大也能调小的播放器（AVAudioEngine）

@MainActor
final class EngineTrack: AudioTrack {
    let duration: TimeInterval
    private(set) var isPlaying = false
    var onFinish: (() -> Void)?
    var onUnexpectedStop: (() -> Void)?

    private let engine = AVAudioEngine()
    private let chain: PlaybackChain
    private let file: AVAudioFile
    private let fileFormat: AVAudioFormat
    private let stereo: AVAudioFormat
    private let sampleRate: Double
    private let totalFrames: AVAudioFramePosition

    /// 暂停时停在哪；播放时 = 这一段是从哪开始放的
    private var baseTime: TimeInterval = 0
    /// 这一段开始放的时刻（系统时钟），拿不到播放节点的时间时用来推算放到哪了
    private var startedAt: CFTimeInterval = 0
    /// 每次重新排队都加 1：旧的「放完了」回调一看号码对不上，就知道不是在说现在这段
    private var generation = 0
    private var rampTask: Task<Void, Never>?
    private let observers = ObserverBag()

    init(url: URL, gainDB: Double) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        // 5.1 这类多声道交给系统播放器，免得声道对不上
        guard format.channelCount >= 1, format.channelCount <= 2,
              format.sampleRate > 0, file.length > 0,
              let stereo = PlaybackChain.stereoFormat(sampleRate: format.sampleRate) else {
            throw LoudnessAnalyzer.Failure.badFormat
        }
        self.file = file
        self.fileFormat = format
        self.stereo = stereo
        self.sampleRate = format.sampleRate
        self.totalFrames = file.length
        self.duration = Double(file.length) / format.sampleRate
        self.chain = PlaybackChain(fileChannels: format.channelCount)

        chain.attach(to: engine)
        chain.connect(in: engine, fileFormat: format, stereo: stereo)
        chain.setGain(gainDB)
        engine.prepare()

        // 插拔耳机、连蓝牙时系统会把引擎停掉，要接上重新放
        observers.add(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        })
    }

    var currentTime: TimeInterval {
        isPlaying ? min(livePosition(), duration) : baseTime
    }

    func play() {
        guard !isPlaying else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            return
        }
        generation += 1
        let gen = generation
        chain.player.stop()   // 清掉旧的排队，节点时间回到 0

        let startFrame = min(max(0, AVAudioFramePosition(baseTime * sampleRate)), totalFrames)
        let remaining = totalFrames - startFrame
        isPlaying = true
        startedAt = CACurrentMediaTime()
        if remaining <= 0 {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.segmentEnded(gen, force: true) }
            }
            return
        }
        chain.player.scheduleSegment(file, startingFrame: startFrame,
                                     frameCount: AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max))),
                                     at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // 这个回调在音频线程上，回主线程再处理（不能在这里停播放节点，会卡死）
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.segmentEnded(gen, force: false) }
            }
        }
        chain.player.play()
    }

    func pause() {
        guard isPlaying else { return }
        baseTime = min(livePosition(), duration)
        generation += 1
        isPlaying = false
        chain.player.stop()
        engine.pause()
    }

    func stop() {
        rampTask?.cancel()
        generation += 1
        isPlaying = false
        chain.player.stop()
        engine.stop()
        observers.removeAll()
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        if wasPlaying {
            generation += 1
            isPlaying = false
            chain.player.stop()
        }
        baseTime = max(0, min(time, duration))
        if wasPlaying {
            play()
        }
    }

    func setGain(_ db: Double, animated: Bool) {
        rampTask?.cancel()
        let target = chain.gainValue(db)
        let start = chain.gain.globalGain
        guard animated, abs(target - start) > 0.1 else {
            chain.gain.globalGain = target
            return
        }
        rampTask = Task { [weak self] in
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.chain.gain.globalGain = start + (target - start) * Float(step) / 10
            }
        }
    }

    // MARK: 内部

    /// 现在放到第几秒：优先问播放节点；引擎刚被系统停掉时问不到，就用系统时钟推算
    private func livePosition() -> TimeInterval {
        if engine.isRunning,
           let nodeTime = chain.player.lastRenderTime,
           let playerTime = chain.player.playerTime(forNodeTime: nodeTime),
           playerTime.sampleRate > 0 {
            return baseTime + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        }
        return wallClockPosition()
    }

    private func wallClockPosition() -> TimeInterval {
        baseTime + max(0, CACurrentMediaTime() - startedAt)
    }

    /// 「这一段放完了」：可能是真的放到结尾，也可能是引擎被系统停掉时顺带通知的
    private func segmentEnded(_ gen: Int, force: Bool) {
        guard gen == generation, isPlaying else { return }
        let position = force ? duration : max(livePosition(), wallClockPosition())
        if position >= duration - 0.75 {
            finishNow()
            return
        }
        // 还没到结尾就没了：
        // - 引擎停了 → 是插拔耳机、来电之类，交给别的地方接着放
        // - 引擎还在转 → 文件后面读不出来了（或者 mp3 的时长是估出来的、比实际长），
        //   等一小会儿确认不是上面那种情况，就当成放完，接着放下一首，免得一直没声音
        guard engine.isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.isPlaying, self.engine.isRunning else { return }
                self.finishNow()
            }
        }
    }

    private func finishNow() {
        generation += 1
        isPlaying = false
        baseTime = duration
        engine.pause()
        onFinish?()
    }

    private func handleConfigurationChange() {
        let wasPlaying = isPlaying
        if wasPlaying {
            // 这时候播放节点的时间已经没了，用系统时钟算放到哪
            baseTime = min(wallClockPosition(), duration)
        }
        generation += 1
        isPlaying = false
        chain.player.stop()
        chain.connect(in: engine, fileFormat: fileFormat, stereo: stereo)
        engine.prepare()
        guard wasPlaying else { return }
        play()
        if !isPlaying {
            onUnexpectedStop?()
        }
    }
}

/// 收着通知的「回执」，自己被释放时顺手全部取消，不用在 deinit 里碰主线程的东西
private final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

// MARK: - 系统自带播放器（备用，只能调小不能调大）

@MainActor
final class SimpleTrack: NSObject, AudioTrack, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?
    var onUnexpectedStop: (() -> Void)?

    init(url: URL, gainDB: Double) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
        setGain(gainDB, animated: false)
    }

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval { player.currentTime }
    var isPlaying: Bool { player.isPlaying }

    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }

    func seek(to time: TimeInterval) {
        player.currentTime = max(0, min(time, player.duration))
    }

    func setGain(_ db: Double, animated: Bool) {
        let volume = Float(min(1, pow(10, db / 20)))
        player.setVolume(volume, fadeDuration: animated ? 0.5 : 0)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.onFinish?() }
    }
}
