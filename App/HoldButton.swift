import SwiftUI
import UIKit

/// 洗澡模式的大按钮：按住一小会儿才生效（水滴一碰就过去了，不会误触）。
/// holdSeconds = 0 时就是普通的轻点按钮。
struct HoldButton<Label: View>: View {
    var holdSeconds: Double
    var cornerRadius: CGFloat
    var fill: Color
    var progressFill: Color
    var accessibilityName: String
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var pressing = false
    @State private var progress: CGFloat = 0
    @State private var bump = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill)
                    GeometryReader { geo in
                        Rectangle()
                            .fill(progressFill)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(pressing ? 0.55 : 0.18), lineWidth: 2)
            }
            .scaleEffect(bump ? 1.05 : (pressing ? 0.97 : 1))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressing { begin() }
                    }
                    .onEnded { _ in
                        end()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
    }

    private func begin() {
        pressing = true
        holdTask?.cancel()
        guard holdSeconds > 0 else { return }
        withAnimation(.linear(duration: holdSeconds)) {
            progress = 1
        }
        let seconds = holdSeconds
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, pressing else { return }
            fire()
        }
    }

    private func end() {
        // 轻点模式：手指抬起时才算按下
        if holdSeconds <= 0 && pressing {
            fire()
        }
        pressing = false
        holdTask?.cancel()
        holdTask = nil
        withAnimation(.easeOut(duration: 0.18)) {
            progress = 0
        }
    }

    private func fire() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        action()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { bump = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.18))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bump = false }
        }
        withAnimation(.easeOut(duration: 0.25)) {
            progress = 0
        }
    }
}

/// 「滑动退出」：要把小圆球一路拖到最右边才算数
struct SlideToExit: View {
    var text: String
    var onComplete: () -> Void

    @State private var offset: CGFloat = 0
    private let knob: CGFloat = 58
    private let inset: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let maxOffset = max(1, geo.size.width - knob - inset * 2)
            let fraction = min(1, offset / maxOffset)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                Capsule()
                    .fill(Theme.teal.opacity(0.35))
                    .frame(width: knob + inset * 2 + offset)
                Text(text)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75 * (1 - fraction)))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob * 0.6)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .overlay {
                        Image(systemName: "chevron.right.2")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.nightTop)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .offset(x: inset + offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = min(max(0, value.translation.width), maxOffset)
                            }
                            .onEnded { _ in
                                if offset >= maxOffset * 0.95 {
                                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                    onComplete()
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    offset = 0
                                }
                            }
                    )
            }
        }
        .frame(height: knob + inset * 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onComplete() }
    }
}
