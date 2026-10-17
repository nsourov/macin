import FootprintCore
import SwiftUI

extension StorageCategory {
    var color: Color {
        switch self {
        case .applications: return Palette.chartTeal
        case .developerArtifacts: return Palette.chartBlue
        case .userFiles: return Palette.chartRose
        case .cachesSupport: return Palette.chartPeach
        case .containersVMs: return Palette.chartGreen
        case .localAIModels: return Palette.chartYellow
        case .other: return Palette.chartGray
        }
    }
}

extension CandidateSource {
    var symbol: String {
        switch self {
        case .xcode: return "hammer.fill"
        case .projectDependencies: return "shippingbox.fill"
        case .caches: return "tray.full.fill"
        case .containers: return "cube.box.fill"
        case .localModels: return "cpu.fill"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .xcode: return Palette.sky
        case .projectDependencies: return Palette.emerald
        case .caches: return Palette.amber
        case .containers: return Palette.blue
        case .localModels: return Palette.coral
        case .other: return Palette.slate
        }
    }
}

enum Theme {
    static let brand = LinearGradient(colors: [Palette.teal, Palette.sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardRadius: CGFloat = 14
}

enum Palette {
    static let emerald = hex(0x10B981)
    static let teal = hex(0x14B8A6)
    static let sky = hex(0x0EA5E9)
    static let blue = hex(0x3B82F6)
    static let amber = hex(0xF59E0B)
    static let coral = hex(0xFB7185)
    static let slate = hex(0x94A3B8)

    static let chartBlue = hex(0x3B82F6)
    static let chartTeal = hex(0x14B8A6)
    static let chartPeach = hex(0xF97316)
    static let chartRose = hex(0xF43F5E)
    static let chartGreen = hex(0x22C55E)
    static let chartYellow = hex(0xEAB308)
    static let chartGray = hex(0x94A3B8)

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .accentColor
    var footnote: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .numeric()
                    .animation(Motion.spring, value: value)
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .hoverLift()
        .accessibilityElement(children: .combine)
    }
}

struct ProportionBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var animated = true
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let target = min(max(fraction, 0), 1)
        let value = (animated && !shown) ? 0 : target
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.gradient).frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 6)
        .animation(Motion.spring, value: target)
        .onAppear {
            guard animated, !shown else { return }
            withAnimation(reduceMotion ? nil : Motion.spring.delay(0.1 + delay)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
