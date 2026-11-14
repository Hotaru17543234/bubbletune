// 在云端 Mac 上检查泡泡音自己的 Swift 代码（不是 Python 版）：
//   1. App/Loudness.swift 测出来的响度，和 Python 版（已经和 ffmpeg 对过）一不一样
//   2. AAC（m4a）文件也能测，结果和原来的 wav 差不多
//   3. App/AudioTracks.swift 的播放链（调音量 + 防破音）离线渲染出来，响度是不是对的、有没有破音
//   4. 各种「不太标准」的文件（Tests/make_problem_files.py 用 ffmpeg 做的）：能不能测、用哪种方法测的
//   5. 有声卡的话，再实际放一下：进度、跳转、放完通知；文件后面坏了 / 时长估错时能不能顺利放完
//
// 用法：swiftc -O App/Loudness.swift App/AudioTracks.swift App/AudioFileSupport.swift Tests/LoudnessCheck/main.swift -o check
//       ./check 测试音频文件夹 奇怪文件文件夹

import Foundation
import AVFoundation

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ok   " : "  FAIL ") + name + (detail.isEmpty ? "" : "  " + detail))
    if !ok { failures.append(name) }
}

func fmt(_ v: Double?) -> String {
    guard let v else { return "nil" }
    return String(format: "%.3f", v)
}

func close(_ a: Double?, _ b: Double?, _ tol: Double) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return abs(a - b) <= tol
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/fixtures")
let problemDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/problems")

@MainActor
func sleep(_ seconds: Double) async {
    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
}

struct Expected {
    let lufs: Double?
    let peakDB: Double?
}

func loadExpected() throws -> [String: Expected] {
    let data = try Data(contentsOf: dir.appendingPathComponent("expected.json"))
    let raw = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
    return raw.mapValues { Expected(lufs: $0["lufs"] as? Double, peakDB: $0["peak_db"] as? Double) }
}

/// 把 wav 转成 AAC 的 m4a（像 Telegram 视频抽出来的声音那样）
func makeM4A(from source: URL, to dest: URL) throws {
    let input = try AVAudioFile(forReading: source)
    let format = input.processingFormat
    try? FileManager.default.removeItem(at: dest)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVEncoderBitRateKey: 256_000,
    ]
    let output = try AVAudioFile(forWriting: dest, settings: settings,
                                 commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)!
    while input.framePosition < input.length {
        try input.read(into: buffer, frameCount: 32_768)
        if buffer.frameLength == 0 { break }
        try output.write(from: buffer)
    }
}

/// 用和 app 里一模一样的播放链离线渲染，返回渲染结果的响度和峰值
func renderThroughChain(_ url: URL, gainDB: Double, bypassLimiter: Bool = false) throws -> LoudnessResult {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    let stereo = PlaybackChain.stereoFormat(sampleRate: rate)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4096)
    let chain = PlaybackChain(fileChannels: file.processingFormat.channelCount)
    chain.attach(to: engine)
    chain.connect(in: engine, fileFormat: file.processingFormat, stereo: stereo)
    chain.setGain(gainDB)
    chain.limiter.bypass = bypassLimiter
    chain.player.scheduleFile(file, at: nil)
    try engine.start()
    chain.player.play()

    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                  frameCapacity: engine.manualRenderingMaximumFrameCount)!
    var meter = LoudnessMeter(sampleRate: rate, channels: 2)
    while engine.manualRenderingSampleTime < file.length {
        let left = file.length - engine.manualRenderingSampleTime
        let frames = AVAudioFrameCount(min(left, AVAudioFramePosition(buffer.frameCapacity)))
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else {
            print("  render status \(status.rawValue)")
            break
        }
        meter.process(UnsafePointer(buffer.floatChannelData!), frames: Int(buffer.frameLength))
    }
    engine.stop()
    return meter.result()
}

/// 返回 false = 没有声卡，后面的实际播放都跳过
@MainActor
func realtimeSmokeTest(_ url: URL) async -> Bool {
    print("5. 实际播放 EngineTrack（需要声卡）")
    let track: EngineTrack
    do {
        track = try EngineTrack(url: url, gainDB: -6)
    } catch {
        check("EngineTrack 打开文件", false, "\(error)")
        return false
    }
    check("时长", abs(track.duration - 20) < 0.01, fmt(track.duration))
    var finished = 0
    track.onFinish = { finished += 1 }
    track.play()
    guard track.isPlaying else {
        print("  （这台机器没有可用的声卡，跳过实际播放）")
        return false
    }
    await sleep(1.0)
    check("放了 1 秒左右", abs(track.currentTime - 1.0) < 0.35, fmt(track.currentTime))
    track.pause()
    let pausedAt = track.currentTime
    await sleep(0.5)
    check("暂停后进度不动", abs(track.currentTime - pausedAt) < 0.001, "\(fmt(pausedAt)) → \(fmt(track.currentTime))")
    track.play()
    await sleep(0.5)
    check("接着放", track.currentTime > pausedAt + 0.2 && track.currentTime < pausedAt + 0.9, fmt(track.currentTime))
    track.seek(to: 10)
    check("跳到 10 秒", abs(track.currentTime - 10) < 0.2, fmt(track.currentTime))
    track.setGain(3, animated: true)
    await sleep(0.8)
    track.seek(to: 18.5)
    await sleep(2.6)
    check("放完会通知一次", finished == 1, "finished = \(finished)")
    check("放完不再算在播放", !track.isPlaying)
    track.stop()
    return true
}

/// 文件后面坏了、或者时长估错了：跳到「结尾前 3 秒」放，看能不能在几秒内放完、接着下一首
@MainActor
func earlyEndTest(_ name: String) async {
    let url = problemDir.appendingPathComponent(name)
    let track: AudioTrack
    do {
        track = try AudioTracks.open(url: url, gainDB: 0)
    } catch {
        print("  \(name)：打不开（\(error)），跳过")
        return
    }
    var finished = 0
    track.onFinish = { finished += 1 }
    track.seek(to: max(0, track.duration - 3))
    track.play()
    let start = Date()
    while finished == 0 && Date().timeIntervalSince(start) < 8 {
        await sleep(0.1)
    }
    let kind = track is EngineTrack ? "EngineTrack" : "SimpleTrack"
    check("\(name) 能放完（\(kind)）", finished == 1,
          String(format: "时长 %.1f 秒，%.1f 秒后收到放完", track.duration, Date().timeIntervalSince(start)))
    track.stop()
}

@MainActor
func runAll() async throws {
    let expected = try loadExpected()

    print("1. 分析器（Swift）和 Python 版对答案")
    for name in expected.keys.sorted() {
        let e = expected[name]!
        let start = Date()
        let r = try await LoudnessAnalyzer.analyze(url: dir.appendingPathComponent(name))
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let ok = close(r.integrated, e.lufs, 0.01) && close(r.peakDB, e.peakDB, 0.01)
        check(name, ok, "swift \(fmt(r.integrated)) / python \(fmt(e.lufs)) LUFS, peak \(fmt(r.peakDB)) / \(fmt(e.peakDB)), \(ms) ms")
    }
    if let e = expected["ebu_case1.wav"] {
        check("EBU 3341 第 1 题 = -23.0", close(e.lufs, -23.0, 0.1), fmt(e.lufs))
    }

    print("2. AAC（m4a）文件")
    for name in ["ebu_case1.wav", "mix_44100_2ch.wav", "mono_quiet.wav"] {
        let m4a = dir.appendingPathComponent((name as NSString).deletingPathExtension + ".m4a")
        try makeM4A(from: dir.appendingPathComponent(name), to: m4a)
        let r = try await LoudnessAnalyzer.analyze(url: m4a)
        check(m4a.lastPathComponent, close(r.integrated, expected[name]?.lufs, 0.2),
              "m4a \(fmt(r.integrated)) / wav \(fmt(expected[name]?.lufs))")
    }

    print("3. 播放链离线渲染（目标 -14 LUFS）")
    let target = LoudnessMode.standard.target
    if let e = expected["mix_44100_2ch.wav"] {
        let out = try renderThroughChain(dir.appendingPathComponent("mix_44100_2ch.wav"), gainDB: 0)
        check("不调音量时原样输出", close(out.integrated, e.lufs, 0.1),
              "in \(fmt(e.lufs)) out \(fmt(out.integrated)), peak \(fmt(out.peakDB))")
    }
    for name in ["quiet_lowpeak.wav", "loud.wav", "mono_quiet.wav"] {
        guard let e = expected[name] else { continue }
        let gain = Loudness.gainDB(loudness: e.lufs, peakDB: e.peakDB, mode: .standard)
        let out = try renderThroughChain(dir.appendingPathComponent(name), gainDB: gain)
        check("\(name) 调 \(String(format: "%+.1f", gain)) dB 后 ≈ -14", close(out.integrated, target, 0.3),
              "in \(fmt(e.lufs)) out \(fmt(out.integrated)), peak \(fmt(out.peakDB))")
    }
    if let e = expected["quiet_highpeak.wav"] {
        let gain = Loudness.gainDB(loudness: e.lufs, peakDB: e.peakDB, mode: .standard)
        let out = try renderThroughChain(dir.appendingPathComponent("quiet_highpeak.wav"), gainDB: gain)
        let wanted = (e.lufs ?? 0) + gain
        check("峰值很高的歌调大 \(String(format: "%+.1f", gain)) dB：不破音", (out.peakDB ?? 99) <= 0.1,
              "peak \(fmt(e.peakDB)) → \(fmt(out.peakDB)) dBFS")
        // 防破音会把最响的地方压下去，整体响度会比算出来的低一点点，1 dB 以内算正常
        check("……响度也差不多到位", close(out.integrated, wanted, 1.0),
              "want \(fmt(wanted)) out \(fmt(out.integrated))")
        let raw = try renderThroughChain(dir.appendingPathComponent("quiet_highpeak.wav"), gainDB: gain, bypassLimiter: true)
        print("  （参考）不开防破音：\(fmt(raw.integrated)) LUFS, peak \(fmt(raw.peakDB))")
    }
    if let e = expected["quiet_lowpeak.wav"] {
        let gain = Loudness.gainDB(loudness: e.lufs, peakDB: e.peakDB, mode: .standard)
        let raw = try renderThroughChain(dir.appendingPathComponent("quiet_lowpeak.wav"), gainDB: gain, bypassLimiter: true)
        print("  （参考）quiet_lowpeak 不开防破音：\(fmt(raw.integrated)) LUFS, peak \(fmt(raw.peakDB))")
    }
    if let e = expected["mix_44100_2ch.wav"] {
        let url = dir.appendingPathComponent("mix_44100_2ch.wav")
        let standard = try renderThroughChain(url, gainDB: Loudness.gainDB(loudness: e.lufs, peakDB: e.peakDB, mode: .standard))
        let loud = try renderThroughChain(url, gainDB: Loudness.gainDB(loudness: e.lufs, peakDB: e.peakDB, mode: .loud))
        let gap = (loud.integrated ?? 0) - (standard.integrated ?? 0)
        check("「大声一点」比「标准」响 4 dB 左右", gap > 3.5 && gap < 4.5,
              "标准 \(fmt(standard.integrated)) / 大声 \(fmt(loud.integrated))，差 \(fmt(gap)) dB，大声的峰值 \(fmt(loud.peakDB))")
    }
    let probe = PlaybackChain(fileChannels: 2)
    for p in probe.limiter.auAudioUnit.parameterTree?.allParameters ?? [] {
        print("  防破音参数 \(p.identifier) = \(p.value) \(p.unitName ?? "") [\(p.minValue) … \(p.maxValue)]")
    }

    try await problemFiles()

    if await realtimeSmokeTest(dir.appendingPathComponent("mix_44100_2ch.wav")) {
        print("6. 文件后面坏了 / 时长估错时能不能放完")
        for name in ["vbr_noxing.mp3", "junk_tail.mp3", "truncated.mp3", "truncated_faststart.m4a",
                     "aac_named.mp3", "adts_named.m4a", "opus.m4a", "cbr.mp3"] {
            await earlyEndTest(name)
        }
    }
}

@MainActor
func problemFiles() async throws {
    print("4. 各种「不太标准」的文件")
    let data = try Data(contentsOf: problemDir.appendingPathComponent("expected.json"))
    let raw = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
    for name in raw.keys.sorted() {
        let info = raw[name]!
        let ref = info["ffmpeg_lufs"] as? Double
        let note = info["note"] as? String ?? ""
        let url = problemDir.appendingPathComponent(name)

        let audioFileOK = (try? AVAudioFile(forReading: url)) != nil
        let avPlayerOK = (try? AVAudioPlayer(contentsOf: url)) != nil
        let trackKind: String
        if let track = try? AudioTracks.open(url: url, gainDB: 0) {
            trackKind = track is EngineTrack ? "EngineTrack" : "SimpleTrack"
        } else {
            trackKind = "放不了"
        }
        print("  · \(name)：\(note)")
        print("      AVAudioFile \(audioFileOK ? "能开" : "打不开")，AVAudioPlayer \(avPlayerOK ? "能开" : "打不开")，泡泡音播放用 \(trackKind)")
        do {
            let m = try await LoudnessAnalyzer.measure(url: url)
            let partial = m.method == .audioFilePartial || m.method == .assetReaderPartial
            let tol = partial ? 1.5 : 0.6
            if let ref {
                check("\(name) 测出来了", close(m.result.integrated, ref, tol),
                      "\(m.method.rawValue)：\(fmt(m.result.integrated)) / ffmpeg \(fmt(ref))")
            } else {
                print("      （ffmpeg 也测不了）泡泡音：\(m.method.rawValue) \(fmt(m.result.integrated))")
            }
        } catch {
            let reason = LoudnessAnalyzer.describe(error)
            // 能放的歌却测不了，才算没做好；本来就放不了的（比如目录丢了的 m4a）只记下来
            if trackKind != "放不了" && ref != nil {
                check("\(name) 测出来了", false, "读不了：\(reason)")
            } else {
                print("      （本来就放不了）读不了：\(reason)")
            }
        }
    }
}

do {
    try await runAll()
} catch {
    print("ERROR: \(error)")
    failures.append("exception")
}
print()
if failures.isEmpty {
    print("all passed ✨")
} else {
    print("\(failures.count) FAILED: \(failures)")
    exit(1)
}
