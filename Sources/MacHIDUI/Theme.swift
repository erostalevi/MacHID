import SwiftUI

/// Shared measurements and small building blocks, so every screen (window, menu bar, settings) looks like one app.
enum Theme {
    static let windowSize = CGSize(width: 1020, height: 680)
    static let sidebarWidth: CGFloat = 348
    static let cardRadius: CGFloat = 14
    static let chipRadius: CGFloat = 10
    static let gap: CGFloat = 10
    static let inset: CGFloat = 18
}

/// A group of related controls on a translucent card.
struct Card<Content: View>: View {
    var title: Text?
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title { title.font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSurface(cornerRadius: Theme.cardRadius)
    }
}

/// A card whose content folds away: a one-line header that opens on click. Keeps long panels compact.
struct DisclosureCard<Content: View>: View {
    var title: Text
    var symbol: String?
    var subtitle: Text?
    @State private var expanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: Text, symbol: String? = nil, subtitle: Text? = nil, expanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle
        self._expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(Motion(reduce: reduceMotion).snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                    title.font(.subheadline.weight(.semibold))
                    if let subtitle { subtitle.font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded { content.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSurface(cornerRadius: Theme.cardRadius)
    }
}

/// Label on the left, value on the right, the control underneath.
struct SettingRow<Control: View>: View {
    var title: Text
    var value: Text?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                title.font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                value?.font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            control
        }
    }
}

/// A segmented control in the app's own style: a capsule track and a highlight that slides to the selection.
struct Segmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var tint: Color = .accentColor
    let label: (Value) -> Text
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(Motion(reduce: reduceMotion).snappy) { selection = option }
                } label: {
                    label(option)
                        .font(.callout.weight(option == selection ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if option == selection {
                                RoundedRectangle(cornerRadius: Theme.chipRadius - 3, style: .continuous)
                                    .fill(tint.opacity(0.35))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius - 3, style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }
}

/// The accent color for a device: its backlight color when it has one, otherwise a color per kind of device.
extension AppModel.DeviceEntry {
    var accent: Color {
        for spec in specs {
            switch values[spec.id] {
            case .color(let color)?: return color.color
            case .effect(let effect)? where effect.color != nil: return effect.color!.color
            default: continue
            }
        }
        switch definition?.category {
        case .keyboard: return .purple
        case .camera: return .teal
        default: return .blue
        }
    }
}

/// Fades its content in once, so views do not pop into place.
struct Appear: ViewModifier {
    @State private var shown = false
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear { withAnimation(Motion(reduce: reduceMotion).smooth.delay(delay)) { shown = true } }
    }
}

extension View {
    func appear(delay: Double = 0) -> some View { modifier(Appear(delay: delay)) }
}
