import SwiftUI
import UIKit

/// 洗澡模式：一进来就锁住，只留「下一首」和「暂停/播放」两个按钮，滑动才能退出
struct ShowerModeView: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(SettingsKeys.holdSeconds) private var holdSeconds: Double = 0.3
    @AppStorage(SettingsKeys.showerAutoplay) private var autoplay = true

    @State private var startedAt = Date()

    /// 24 小时制的「20:15」
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 按屏幕高度决定各部分大小，小屏 iPhone 也能一屏放下
    private struct Metrics {
        let clockFont: CGFloat
        let art: CGFloat
        let titleFont: CGFloat
        let titleLines: Int
        let playHeight: CGFloat
        let nextHeight: CGFloat
        let nextIcon: CGFloat
        let gap: CGFloat

        init(height: CGFloat) {
            if height >= 800 {
                clockFont = 72; art = 150; titleFont = 28; titleLines = 2
                playHeight = 96; nextHeight = 170; nextIcon = 54; gap = 18
            } else if height >= 700 {
                clockFont = 60; art = 110; titleFont = 26; titleLines = 1
                playHeight = 84; nextHeight = 150; nextIcon = 48; gap = 14
            } else {
                clockFont = 48; art = 72; titleFont = 22; titleLines = 1
                playHeight = 72; nextHeight = 130; nextIcon = 40; gap = 10
            }
        }
    }

    var body: some View {
        ZStack {
            BubbleBackground(dark: true)

            GeometryReader { geo in
                let m = Metrics(height: geo.size.height)
                VStack(spacing: 0) {
                    clockAndTimer(m)
                        .padding(.top, m.gap)

                    Spacer(minLength: 8)

                    nowPlaying(m)

                    Spacer(minLength: 8)

                    controls(m)

                    SlideToExit(text: "滑动退出洗澡模式") {
                        dismiss()
                    }
                    .padding(.top, m.gap)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 22)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // 从屏幕边缘滑一下不会直接退出，要滑第二次（防水滴从边缘划过）
        .defersSystemGestures(on: .all)
        .onAppear {
            startedAt = Date()
            UIApplication.shared.isIdleTimerDisabled = true
            if autoplay && !player.isPlaying {
                player.play()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }

    // MARK: - 时钟 + 洗澡计时

    private func clockAndTimer(_ m: Metrics) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                Text(Self.clock.string(from: context.date))
                    .font(.system(size: m.clockFont, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Image(systemName: "shower.fill")
                    Text("已经洗了 \(Theme.time(context.date.timeIntervalSince(startedAt)))")
                        .monospacedDigit()
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.teal)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Theme.nightCard, in: Capsule())
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 正在播放

    private func nowPlaying(_ m: Metrics) -> some View {
        VStack(spacing: m.gap * 0.8) {
            ArtworkView(song: player.currentSong, size: m.art, cornerRadius: m.art * 0.17)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(player.currentSong?.title ?? "还没有选歌")
                    .font(.system(size: m.titleFont, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(m.titleLines)
                    .minimumScaleFactor(0.7)
                Text(player.currentSong?.displayArtist ?? "按下面的按钮开始")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let total = max(player.duration, 0.1)
                let ratio = min(1, max(0, player.currentTime / total))
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Theme.teal)
                                .frame(width: geo.size.width * CGFloat(ratio))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text(Theme.time(player.currentTime))
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: player.orderMode.icon)
                            Text(player.orderMode.shortTitle)
                            Text("·")
                            Image(systemName: player.repeatMode.icon)
                            Text(player.repeatMode.title)
                        }
                        Spacer()
                        Text(Theme.time(player.duration))
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(height: 30)
        }
    }

    // MARK: - 两个按钮

    private func controls(_ m: Metrics) -> some View {
        VStack(spacing: m.gap * 0.8) {
            HoldButton(holdSeconds: holdSeconds,
                       cornerRadius: 34,
                       fill: Color.white.opacity(0.12),
                       progressFill: Theme.teal.opacity(0.45),
                       accessibilityName: player.isPlaying ? "暂停" : "播放",
                       action: { player.togglePlayPause() }) {
                HStack(spacing: 12) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .bold))
                    Text(player.isPlaying ? "暂停" : "播放")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
            }
            .frame(height: m.playHeight)

            HoldButton(holdSeconds: holdSeconds,
                       cornerRadius: 40,
                       fill: Theme.blue.opacity(0.85),
                       progressFill: Theme.teal,
                       accessibilityName: "下一首",
                       action: { player.next() }) {
                VStack(spacing: 6) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: m.nextIcon, weight: .bold))
                    Text("下一首")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                    if holdSeconds > 0 {
                        Text("按住一下下就切歌")
                            .font(.footnote.weight(.medium))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(.white)
            }
            .frame(height: m.nextHeight)
        }
    }
}
