import SwiftUI

extension Settings.AppearanceMode {
    /// `nil` означает, что SwiftUI следует текущему оформлению macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// Единая палитра и типографика.
enum Theme {

    static func accentColors(_ accent: Settings.AccentTheme) -> [Color] {
        switch accent {
        case .aurora: return [Color(hex: 0x5B8CFF), Color(hex: 0x22D3EE), Color(hex: 0x8B5CF6)]
        case .ember:  return [Color(hex: 0xFF7A45), Color(hex: 0xFFB443), Color(hex: 0xE8437A)]
        case .mint:   return [Color(hex: 0x22C55E), Color(hex: 0x14B8A6), Color(hex: 0x84CC16)]
        case .violet: return [Color(hex: 0x8B5CF6), Color(hex: 0xD946EF), Color(hex: 0x6366F1)]
        }
    }

    static func gradient(_ accent: Settings.AccentTheme) -> LinearGradient {
        LinearGradient(colors: accentColors(accent), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func primary(_ accent: Settings.AccentTheme) -> Color { accentColors(accent)[0] }

    static let danger = Color(hex: 0xFF4D5E)
    static let warning = Color(hex: 0xFFB020)
    static let success = Color(hex: 0x34D399)

    /// Цвета для подписей голосов. Отличаются друг от друга по тону, а не по
    /// яркости: рядом стоящие реплики должны различаться с одного взгляда.
    static let voiceColors: [Color] = [
        Color(hex: 0x34D399), Color(hex: 0x60A5FA), Color(hex: 0xF472B6),
        Color(hex: 0xFBBF24), Color(hex: 0xA78BFA), Color(hex: 0x22D3EE)
    ]

    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 18
}

/// Максимально простой жест: название «голос» лишь угадывается в ритме линии,
/// но знак остаётся абстрактной звуковой волной даже при внимательном взгляде.
struct GolosMark: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width, h = size.height
            path.move(to: CGPoint(x: w * 0.06, y: h * 0.68))
            path.addLine(to: CGPoint(x: w * 0.06, y: h * 0.49))
            path.addCurve(to: CGPoint(x: w * 0.27, y: h * 0.60),
                          control1: CGPoint(x: w * 0.06, y: h * 0.30),
                          control2: CGPoint(x: w * 0.22, y: h * 0.30))
            path.addCurve(to: CGPoint(x: w * 0.42, y: h * 0.54),
                          control1: CGPoint(x: w * 0.31, y: h * 0.76),
                          control2: CGPoint(x: w * 0.42, y: h * 0.72))
            path.addCurve(to: CGPoint(x: w * 0.60, y: h * 0.20),
                          control1: CGPoint(x: w * 0.46, y: h * 0.38),
                          control2: CGPoint(x: w * 0.55, y: h * 0.07))
            path.addCurve(to: CGPoint(x: w * 0.75, y: h * 0.56),
                          control1: CGPoint(x: w * 0.67, y: h * 0.07),
                          control2: CGPoint(x: w * 0.69, y: h * 0.43))
            path.addCurve(to: CGPoint(x: w * 0.91, y: h * 0.53),
                          control1: CGPoint(x: w * 0.80, y: h * 0.74),
                          control2: CGPoint(x: w * 0.91, y: h * 0.72))
            path.addCurve(to: CGPoint(x: w * 0.98, y: h * 0.56),
                          control1: CGPoint(x: w * 0.94, y: h * 0.40),
                          control2: CGPoint(x: w * 0.95, y: h * 0.46))

            context.stroke(path,
                           with: .linearGradient(
                            Gradient(colors: [Color(hex: 0x677CFF), Color(hex: 0x7C5CFA)]),
                            startPoint: .zero, endPoint: CGPoint(x: w, y: 0)),
                           style: StrokeStyle(lineWidth: max(1.4, h * 0.11),
                                              lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("голос")
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Фон приложения: несколько мягких пятен, которые медленно плывут.
///
/// Движение сделано одним поворотом растеризованной группы, а не пересчётом
/// смещений в теле view. Разница принципиальная: смещения, посчитанные от
/// анимируемого значения, заставляли SwiftUI перевычислять тело шестьдесят раз
/// в секунду и стоили около 14% процессора постоянно. Поворот готовой текстуры
/// целиком отдаётся Core Animation и почти ничего не стоит.
struct AuroraBackground: View {
    let accent: Settings.AccentTheme
    var animated: Bool = true

    @State private var rotation: Double = 0

    var body: some View {
        let colors = Theme.accentColors(accent)

        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(colors[0], size: w * 0.85).offset(x: -w * 0.30, y: -h * 0.34)
                    blob(colors[1], size: w * 0.70).offset(x: w * 0.36, y: -h * 0.10)
                    blob(colors[2], size: w * 0.75).offset(x: w * 0.06, y: h * 0.44)
                }
                .frame(width: w, height: h)
                // Растеризуем один раз: дальше это просто текстура.
                .drawingGroup()
                // Масштаб с запасом, чтобы при повороте не открывались углы.
                .scaleEffect(1.65)
                .rotationEffect(.degrees(rotation))
                .opacity(0.22)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 120).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

/// Карточка — базовый контейнер интерфейса.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

struct SectionTitle: View {
    let text: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.system(.title2, design: .rounded, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Небольшая метка-пилюля.
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(filled ? color.opacity(0.9) : color.opacity(0.14))
            )
            .foregroundStyle(filled ? Color.white : color)
    }
}

/// Заглушка для пустых экранов.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // Без фиксированной ширины: в узкой колонке она распирала вёрстку.
                .frame(maxWidth: 380, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Кнопка-акцент с градиентом.
struct AccentButtonStyle: ButtonStyle {
    let accent: Settings.AccentTheme
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                prominent
                    ? AnyShapeStyle(Theme.gradient(accent))
                    : AnyShapeStyle(Theme.primary(accent).opacity(0.16)),
                in: Capsule()
            )
            .foregroundStyle(prominent ? Color.white : Theme.primary(accent))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// Плавное появление блока сверху вниз — используется для лент и списков.
    func slideIn(_ index: Int) -> some View {
        self.transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            )
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.82).delay(Double(index) * 0.015), value: index)
    }
}
