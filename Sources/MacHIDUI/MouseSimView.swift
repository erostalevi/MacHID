import SwiftUI
import MacHIDDomain

/// A mouse seen from above. Every physical button is a hotspot; the glow under the logo follows the lighting setting.
struct MouseSimView: View {
    struct Button: Identifiable {
        let id: String
        let title: String
        /// macOS button number the event tap sees (0 left, 1 right, 2 middle, 3+ extra); nil when the button never
        /// reaches the Mac (it is handled inside the mouse).
        let quartzButton: Int?
    }

    /// The buttons of the G203 LIGHTSYNC.
    static let g203: [Button] = [
        Button(id: "left", title: "Left button", quartzButton: 0),
        Button(id: "right", title: "Right button", quartzButton: 1),
        Button(id: "middle", title: "Wheel click", quartzButton: 2),
        Button(id: "back", title: "Back", quartzButton: 3),
        Button(id: "forward", title: "Forward", quartzButton: 4),
        Button(id: "dpi", title: "DPI button", quartzButton: nil),
    ]

    var accent: Color
    var lightsOn = true
    var dpi: Int?
    var selected: String?
    var remapped: Set<String> = []
    var onSelect: (String) -> Void = { _ in }

    @State private var hovered: String?
    @State private var pressed: String?
    private let width: CGFloat = 220, height: CGFloat = 380

    private var body_: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 108, bottomLeadingRadius: 84, bottomTrailingRadius: 84, topTrailingRadius: 108, style: .continuous)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [lightsOn ? accent.opacity(0.45) : .clear, .clear], center: .center, startRadius: 0, endRadius: 210))
                .frame(width: 420, height: 420)
                .offset(y: 70)
            ZStack(alignment: .topLeading) {
                body_.fill(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                body_.strokeBorder(.white.opacity(0.4), lineWidth: 1.2)
                // Button faces, clipped to the body.
                ZStack(alignment: .topLeading) {
                    region("left", x: 0, y: 0, w: width / 2 - 1, h: 168)
                    region("right", x: width / 2 + 1, y: 0, w: width / 2 - 1, h: 168)
                    Path { path in
                        path.move(to: CGPoint(x: width / 2, y: 0)); path.addLine(to: CGPoint(x: width / 2, y: 168))
                        path.move(to: CGPoint(x: 0, y: 168)); path.addLine(to: CGPoint(x: width, y: 168))
                    }.stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .clipShape(body_)
                // Wheel, DPI button, logo glow.
                capsule("middle", x: width / 2 - 13, y: 38, w: 26, h: 62, radius: 13)
                capsule("dpi", x: width / 2 - 9, y: 112, w: 18, h: 30, radius: 9)
                Circle().fill(lightsOn ? accent : .gray.opacity(0.4)).frame(width: 26, height: 26)
                    .shadow(color: lightsOn ? accent.opacity(0.9) : .clear, radius: 14)
                    .offset(x: width / 2 - 13, y: 258)
                    .animation(.smooth(duration: 0.4), value: accent)
                // Side buttons sit on the left edge.
                capsule("forward", x: -7, y: 190, w: 14, h: 46, radius: 7)
                capsule("back", x: -7, y: 244, w: 14, h: 46, radius: 7)
                if let dpi {
                    Text(verbatim: "\(dpi)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: width).offset(y: 312)
                        .contentTransition(.numericText(value: Double(dpi)))
                }
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 14)
        }
        .frame(width: 420, height: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Mouse illustration"))
    }

    // MARK: Parts

    private func fill(_ id: String) -> Color {
        if pressed == id { return accent.opacity(0.55) }
        if selected == id { return accent.opacity(0.42) }
        if hovered == id { return accent.opacity(0.28) }
        return remapped.contains(id) ? accent.opacity(0.14) : .clear
    }

    private func region(_ id: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        Rectangle().fill(fill(id)).frame(width: w, height: h).offset(x: x, y: y)
            .contentShape(Rectangle())
            .modifier(Hotspot(id: id, title: title(id), hovered: $hovered, pressed: $pressed, onSelect: onSelect))
            .animation(.snappy(duration: 0.18), value: hovered)
            .animation(.snappy(duration: 0.18), value: selected)
    }

    private func capsule(_ id: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected == id || hovered == id || pressed == id ? accent.opacity(0.9) : .white.opacity(id == "middle" ? 0.85 : 0.5))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 0.8))
            .frame(width: w, height: h)
            .shadow(color: selected == id ? accent : .clear, radius: 8)
            .offset(x: x, y: y)
            .contentShape(Rectangle().inset(by: -6))
            .modifier(Hotspot(id: id, title: title(id), hovered: $hovered, pressed: $pressed, onSelect: onSelect))
            .animation(.snappy(duration: 0.18), value: hovered)
            .animation(.snappy(duration: 0.18), value: selected)
    }

    private func title(_ id: String) -> String { Self.g203.first { $0.id == id }?.title ?? id }

}

/// Hover, press and click handling shared by the hotspots.
struct Hotspot: ViewModifier {
    let id: String
    let title: String
    @Binding var hovered: String?
    @Binding var pressed: String?
    let onSelect: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onHover { inside in hovered = inside ? id : (hovered == id ? nil : hovered) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = id }
                .onEnded { _ in pressed = nil; onSelect(id) })
            .help(Text(LocalizedStringKey(title)))
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey(title)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSelect(id) }
    }
}
