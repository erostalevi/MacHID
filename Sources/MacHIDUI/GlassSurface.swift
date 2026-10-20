import SwiftUI

/// The only place that knows which glass API exists. Views call `.glassSurface(...)`; on macOS 26+ that is
/// Liquid Glass, on macOS 14-25 a system material, and with "Reduce transparency" a plain opaque surface.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.quaternary))
        } else {
            #if compiler(>=6.2)
            // The Liquid Glass API only exists in the macOS 26 SDK (Xcode 26, Swift 6.2). Older toolchains
            // cannot compile it at all, so an `#available` check alone is not enough.
            if #available(macOS 26.0, *) {
                content.glassEffect(glass, in: shape)
            } else {
                materialFallback(content, shape)
            }
            #else
            materialFallback(content, shape)
            #endif
        }
    }

    private func materialFallback(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay { if let tint { shape.fill(tint.opacity(0.12)) } }
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.35)) }
        return interactive ? glass.interactive() : glass
    }
    #endif
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 24, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

/// Groups nearby glass so neighboring shapes blend and morph together (Liquid Glass); a plain container before macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Animations honor the system "Reduce motion" setting: they collapse to an instant change.
struct Motion {
    var reduce: Bool
    var smooth: Animation { reduce ? .linear(duration: 0.01) : .smooth(duration: 0.38) }
    var snappy: Animation { reduce ? .linear(duration: 0.01) : .snappy(duration: 0.28) }
    var press: Animation { reduce ? .linear(duration: 0.01) : .spring(response: 0.22, dampingFraction: 0.7) }
}

extension View {
    func motion<V: Equatable>(_ keyPath: KeyPath<Motion, Animation>, value: V) -> some View {
        modifier(MotionModifier(keyPath: keyPath, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let keyPath: KeyPath<Motion, Animation>
    let value: V
    func body(content: Content) -> some View {
        content.animation(Motion(reduce: reduceMotion)[keyPath: keyPath], value: value)
    }
}

/// A capsule button on a glass surface that lifts on hover and sinks when pressed.
struct PillButtonStyle: ButtonStyle {
    var tint: Color?
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, selected: selected)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        let selected: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let motion = Motion(reduce: reduceMotion)
            configuration.label
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(cornerRadius: 20, tint: selected ? (tint ?? .accentColor) : nil, interactive: true)
                .scaleEffect(configuration.isPressed ? 0.94 : (hovering && enabled ? 1.03 : 1))
                .opacity(enabled ? 1 : 0.5)
                .animation(motion.press, value: configuration.isPressed)
                .animation(motion.snappy, value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}
