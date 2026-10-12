import SwiftUI

/// 软萌水泡泡配色
enum Theme {
    static let sky = Color(red: 0.87, green: 0.95, blue: 1.00)      // 浅天蓝
    static let mint = Color(red: 0.89, green: 0.98, blue: 0.95)     // 浅薄荷
    static let blue = Color(red: 0.29, green: 0.62, blue: 0.92)     // 泡泡蓝（主色）
    static let deepBlue = Color(red: 0.18, green: 0.40, blue: 0.70)
    static let teal = Color(red: 0.40, green: 0.80, blue: 0.72)     // 薄荷绿
    static let pink = Color(red: 1.00, green: 0.72, blue: 0.81)     // 小粉红
    static let ink = Color(red: 0.17, green: 0.23, blue: 0.33)      // 文字深蓝灰
    static let card = Color.white.opacity(0.72)

    // 洗澡模式（深色）
    static let nightTop = Color(red: 0.05, green: 0.10, blue: 0.17)
    static let nightBottom = Color(red: 0.06, green: 0.16, blue: 0.24)
    static let nightCard = Color.white.opacity(0.08)

    /// 每首歌一个固定的柔和颜色，没有封面时用
    static func pastel(for id: UUID) -> Color {
        let hue = Double(id.uuid.0) / 255.0
        return Color(hue: hue, saturation: 0.35, brightness: 0.97)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// 一个泡泡的位置、大小和速度
private struct BubbleSpec: Sendable {
    let x: Double       // 0...1 横向位置
    let radius: Double
    let speed: Double   // 每秒上升多少个「屏幕高度」
    let phase: Double   // 0...1 起始高度
    let wobble: Double
}

/// 固定的「随机」泡泡，每次打开位置都一样
private let bubbleField: [BubbleSpec] = {
    var seed: UInt64 = 20261012
    func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(UInt64(1) << 31)
    }
    var list: [BubbleSpec] = []
    for _ in 0..<16 {
        list.append(BubbleSpec(x: rand(),
                               radius: 6 + rand() * 26,
                               speed: 0.010 + rand() * 0.022,
                               phase: rand(),
                               wobble: 0.4 + rand() * 0.8))
    }
    return list
}()

/// 慢慢往上飘的小泡泡背景
struct BubbleBackground: View {
    var dark = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Theme.nightTop, Theme.nightBottom] : [Theme.sky, Theme.mint, .white],
                           startPoint: .top, endPoint: .bottom)
            let isDark = dark
            let still = reduceMotion
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: still)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                Canvas { gc, size in
                    let t: Double = still ? 0 : now
                    for b in bubbleField {
                        let r = CGFloat(b.radius)
                        let progress = CGFloat((b.phase + t * b.speed).truncatingRemainder(dividingBy: 1))
                        let travel: CGFloat = size.height + r * 4
                        let y: CGFloat = size.height + r * 2 - progress * travel
                        let drift = CGFloat(sin(t * b.wobble + b.phase * 6) * 10)
                        let x: CGFloat = size.width * CGFloat(b.x) + drift
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        let circle = Path(ellipseIn: rect)
                        gc.fill(circle, with: .color(.white.opacity(isDark ? 0.04 : 0.35)))
                        gc.stroke(circle, with: .color(.white.opacity(isDark ? 0.10 : 0.75)), lineWidth: 1.2)
                        let shine = CGRect(x: rect.minX + r * 0.45, y: rect.minY + r * 0.40,
                                           width: r * 0.45, height: r * 0.30)
                        gc.fill(Path(ellipseIn: shine), with: .color(.white.opacity(isDark ? 0.10 : 0.8)))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 歌曲封面（没有封面就画一个带音符的彩色泡泡）
struct ArtworkView: View {
    let song: Song?
    var size: CGFloat
    var cornerRadius: CGFloat = 12
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [song.map { Theme.pastel(for: $0.id) } ?? Theme.sky, .white],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.blue.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: song?.artworkKey) {
            image = nil
            if let song {
                image = await ArtworkCache.shared.image(for: song)
            }
        }
    }
}

/// 播放中的小跳动音柱
struct PlayingBars: View {
    var animating: Bool
    var color: Color = Theme.blue

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let wave: Double = abs(sin(t * 5 + Double(i) * 1.3))
                    let h: CGFloat = animating ? CGFloat(0.35 + 0.65 * wave) : 0.35
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 14 * h)
                }
            }
            .frame(width: 15, height: 14, alignment: .bottom)
        }
    }
}

/// 小提示条
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1))
            .shadow(color: Theme.blue.opacity(0.18), radius: 12, y: 4)
            .padding(.horizontal, 24)
    }
}
