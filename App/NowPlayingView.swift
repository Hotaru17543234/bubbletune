import SwiftUI

/// 点底部小播放条后弹出的完整播放页
struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    var openShowerMode: () -> Void

    var body: some View {
        ZStack {
            BubbleBackground()

            GeometryReader { geo in
                let compact = geo.size.height < 700
                let art = max(120, min(260, geo.size.height * 0.33, geo.size.width - 80))
                VStack(spacing: compact ? 14 : 22) {
                    Spacer(minLength: compact ? 12 : 24)

                    ArtworkView(song: player.currentSong, size: art, cornerRadius: art * 0.12)
                        .shadow(color: Theme.blue.opacity(0.25), radius: 24, y: 12)

                    VStack(spacing: 6) {
                        Text(player.currentSong?.title ?? "还没有选歌")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(player.currentSong?.displayArtist ?? "在列表里点一首歌吧")
                            .font(.body)
                            .foregroundStyle(Theme.ink.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)

                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        ProgressSlider(current: player.currentTime,
                                       duration: player.duration,
                                       onSeek: { player.seek(to: $0) })
                    }
                    .padding(.horizontal, 28)

                    transport

                    modePickers
                        .padding(.horizontal, 24)

                    Spacer(minLength: 0)

                    Button(action: openShowerMode) {
                        Label("进入洗澡模式", systemImage: "shower.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.blue, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(color: Theme.blue.opacity(0.35), radius: 10, y: 5)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .fontDesign(.rounded)
    }

    private var transport: some View {
        HStack(spacing: 34) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 74))
                    .symbolRenderingMode(.hierarchical)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
            }
        }
        .foregroundStyle(Theme.blue)
        .buttonStyle(.plain)
    }

    private var modePickers: some View {
        VStack(spacing: 10) {
            Picker("播放顺序", selection: Binding(get: { player.orderMode },
                                               set: { player.setOrderMode($0) })) {
                ForEach(OrderMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            Picker("播完之后", selection: Binding(get: { player.repeatMode },
                                              set: { player.setRepeatMode($0) })) {
                ForEach(RepeatMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
        .pickerStyle(.segmented)
    }
}

/// 可以拖动的进度条
struct ProgressSlider: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        let shown = dragValue ?? current
        let upper = max(duration, 0.1)
        VStack(spacing: 4) {
            Slider(value: Binding(get: { min(shown, upper) }, set: { dragValue = $0 }),
                   in: 0...upper,
                   onEditingChanged: { editing in
                       if !editing, let v = dragValue {
                           onSeek(v)
                           dragValue = nil
                       }
                   })
            .tint(Theme.blue)
            HStack {
                Text(Theme.time(shown))
                Spacer()
                Text("-" + Theme.time(max(0, duration - shown)))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Theme.ink.opacity(0.55))
        }
    }
}
