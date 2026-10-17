import SwiftUI

enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let snappy = Animation.snappy(duration: 0.28)
    static let smooth = Animation.smooth(duration: 0.35)
    static let gentle = Animation.easeOut(duration: 0.9)
}

struct HoverLift: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var scale: CGFloat = 1.012
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: hovering ? 14 : 0, y: hovering ? 6 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.35 : 0), lineWidth: 1)
            )
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .padding(.horizontal, -8)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct Appear: ViewModifier {
    let delay: Double
    var offset: CGFloat = 14
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : offset)
            .scaleEffect(shown || reduceMotion ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.spring.delay(delay)) { shown = true }
            }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

extension View {
    func hoverLift(radius: CGFloat = Theme.cardRadius, scale: CGFloat = 1.012) -> some View {
        modifier(HoverLift(radius: radius, scale: scale))
    }

    func hoverHighlight() -> some View { modifier(HoverHighlight()) }

    func appear(_ index: Int = 0, step: Double = 0.05, offset: CGFloat = 14) -> some View {
        modifier(Appear(delay: Double(min(index, 12)) * step, offset: offset))
    }

    func numeric() -> some View { contentTransition(.numericText()) }
}

extension AnyTransition {
    static var pageSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.99, anchor: .top)),
            removal: .opacity
        )
    }

    static var slideDown: AnyTransition {
        .move(edge: .top).combined(with: .opacity)
    }
}

struct SpinningRing: View {
    var lineWidth: CGFloat = 10
    @State private var rotating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(rotating ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: rotating)
        }
        .onAppear { rotating = true }
        .accessibilityLabel("In progress")
    }
}
