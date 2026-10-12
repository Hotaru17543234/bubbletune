import SwiftUI

enum SettingsKeys {
    static let holdSeconds = "showerHoldSeconds"
    static let showerAutoplay = "showerAutoplay"
}

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var telegram: TelegramSync
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKeys.holdSeconds) private var holdSeconds: Double = 0.3
    @AppStorage(SettingsKeys.showerAutoplay) private var autoplay = true

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
