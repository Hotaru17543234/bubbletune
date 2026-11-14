import SwiftUI

enum SettingsKeys {
    static let holdSeconds = "showerHoldSeconds"
    static let showerAutoplay = "showerAutoplay"
    static let loudnessNormalize = "loudnessNormalize"
    static let loudnessMode = "loudnessMode"
}

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var telegram: TelegramSync
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.holdSeconds) private var holdSeconds: Double = 0.3
    @AppStorage(SettingsKeys.showerAutoplay) private var autoplay = true
    @AppStorage(SettingsKeys.loudnessNormalize) private var normalize = true
    @AppStorage(SettingsKeys.loudnessMode) private var loudnessMode = LoudnessMode.standard.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        TelegramSetupView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "paperplane.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Telegram 频道同步")
                                    .foregroundStyle(Theme.ink)
                                Text(telegramSummary)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                    }
                } footer: {
                    Text("登录你自己的 Telegram 账号，把一个频道里的音频（视频只要声音）自动同步进泡泡音。")
                }

                Section {
                    Toggle("每首歌一样响", isOn: $normalize)
                    if normalize {
                        Picker("音量", selection: $loudnessMode) {
                            Text("标准").tag(LoudnessMode.standard.rawValue)
                            Text("大声一点（水声大时）").tag(LoudnessMode.loud.rawValue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在放的这首")
                            .foregroundStyle(Theme.ink)
                        Text(nowPlayingLoudnessText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.blue)
                            .animation(nil, value: nowPlayingLoudnessText)
                    }
                    .padding(.vertical, 2)
                    LabeledContent("测好的歌", value: library.loudnessProgressText)
                    if !library.failedLoudnessSongs.isEmpty {
                        NavigationLink {
                            LoudnessFailuresView()
                        } label: {
                            Label("读不了的歌（\(library.failedLoudnessSongs.count) 首）", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                } header: {
                    Text("音量统一")
                } footer: {
                    Text("泡泡音会在后台把每首歌「听」一遍，记下它有多响，音乐文件本身一点都不改。播放时太响的调小、太小声的调大，调大时自带防破音。「大声一点」比「标准」响 4 dB 左右。新导入、新同步的歌也会自动测。")
                }
                .onChange(of: normalize) { player.refreshGain() }
                .onChange(of: loudnessMode) { player.refreshGain() }

                Section {
                    Picker("按钮怎样才算按下", selection: $holdSeconds) {
                        Text("轻点就生效").tag(0.0)
                        Text("按住 0.3 秒").tag(0.3)
                        Text("按住 0.6 秒（最防水滴）").tag(0.6)
                    }
                    Toggle("进入时自动开始播放", isOn: $autoplay)
                } header: {
                    Text("洗澡模式")
                } footer: {
                    Text("水滴落在屏幕上会被当成手指。按住一小会儿才生效，水滴一碰就过去了，不会乱切歌。")
                }

                Section("怎么导入歌曲") {
                    tip("plus.circle.fill", "在泡泡音里点右上角「＋」，从「文件」App 或 iCloud 云盘选歌，可以一次选很多首。")
                    tip("paperplane.fill", "在上面开启「Telegram 频道同步」，频道里的歌会自动同步进来。")
                    tip("square.and.arrow.up", "在 Telegram、浏览器、网盘等 App 里打开歌曲文件，点「分享」→「泡泡音」。")
                    tip("folder.fill", "「文件」App →「我的 iPhone」→「泡泡音」文件夹，直接把歌拖进去或者拷进去。")
                    tip("desktopcomputer", "Windows 电脑：用「Apple 设备」App（或 iTunes），连上 iPhone →「文件」→ 泡泡音 →「添加文件」。Mac：在访达里选中 iPhone →「文件」，把歌拖到泡泡音上。")
                }

                Section {
                    tip("1.circle.fill", "「设置」→「辅助功能」→「引导式访问」，打开它并设一个密码。")
                    tip("2.circle.fill", "打开泡泡音的洗澡模式，连按三下侧边按钮，点「引导式访问」。")
                    tip("3.circle.fill", "用手指圈出不想让它响应的地方（比如上面的时钟和封面），留着「下一首」「暂停」两个按钮，再点「开始」。想连按钮也锁住，就在「选项」里关掉「触摸」。")
                    tip("4.circle.fill", "洗完了再连按三下侧边按钮，输入密码就能退出。")
                } header: {
                    Text("想锁得更牢？（系统自带的引导式访问）")
                } footer: {
                    Text("引导式访问可以让手机只能停在泡泡音里，连从底部上滑回主屏幕都不行。音量键照样能调音量。")
                }

                Section("关于") {
                    LabeledContent("歌曲数量", value: "\(library.songs.count) 首")
                    LabeledContent("支持的格式", value: "mp3 · m4a · aac · flac · wav · aiff")
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好啦") { dismiss() }
                }
            }
        }
        .fontDesign(.rounded)
        .tint(Theme.blue)
    }

    /// 正在放的歌：原本多响、现在调了多少。改开关和音量档位时会跟着变
    private var nowPlayingLoudnessText: String {
        guard let song = player.currentSong else { return "现在没在放歌" }
        if song.needsLoudness {
            return library.loudnessFailures[song.id] != nil ? "这首读不了，不调（原因在下面）" : "这首还在测，测好马上调"
        }
        guard let lufs = song.loudness else { return "这首几乎没声音，不调" }
        let original = String(format: "原本 %.1f LUFS", lufs)
        guard normalize else { return original + " · 统一关着，不调" }
        let mode = LoudnessMode(rawValue: loudnessMode) ?? .standard
        let gain = Loudness.gainDB(loudness: lufs, peakDB: song.peakDB, mode: mode)
        var text = original + " → " + Loudness.describeGain(gain)
        if gain > 0.05 && !player.canBoost {
            text += "（这首只能调小）"
        }
        return text
    }

    private var telegramSummary: String {
        switch telegram.loginStep {
        case .ready:
            if let channel = telegram.channel {
                return "已开启 · \(channel.title)"
            }
            return "已登录，还没选频道"
        case .needsCredentials:
            return "还没设置"
        default:
            return "还没登录完"
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.blue)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// 测不了音量的歌：是哪几首、为什么。这几首照样能放，只是不会自动调音量
struct LoudnessFailuresView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        List {
            Section {
                ForEach(library.failedLoudnessSongs) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.song.displayTitle)
                            .foregroundStyle(Theme.ink)
                        Text((item.song.fileName as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(Theme.ink.opacity(0.6))
                        Text(item.reason)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.ink.opacity(0.45))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("这些歌照样能放，只是不会自动调音量。可以截图发给做 app 的人看看原因～")
            }
            Section {
                Button {
                    library.retryFailedLoudness()
                } label: {
                    Label(library.loudnessBusy ? "正在测…" : "再测一次", systemImage: "arrow.clockwise")
                }
                .disabled(library.loudnessBusy)
            }
        }
        .navigationTitle("读不了的歌")
        .navigationBarTitleDisplayMode(.inline)
    }
}
