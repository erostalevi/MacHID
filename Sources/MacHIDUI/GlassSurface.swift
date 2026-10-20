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

/// A capsule button on a glass surface.
struct PillButtonStyle: ButtonStyle {
    var tint: Color?
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassSurface(cornerRadius: 20, tint: selected ? (tint ?? .accentColor) : nil, interactive: true)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
