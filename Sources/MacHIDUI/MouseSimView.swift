import SwiftUI
import MacHIDDomain

/// A mouse seen from above. Every physical button is a hit area; clicking anywhere on a button selects it. The glow under
/// the logo follows the lighting setting. Drawn flat and matte on purpose: the glass belongs to the window.
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

    // Geometry, in the body's own coordinates (origin top-left of the body).
    private static let width: CGFloat = 220, height: CGFloat = 380, split: CGFloat = 168
    private static let margin = CGSize(width: 40, height: 20)
    private static let wheel = CGRect(x: width / 2 - 13, y: 38, width: 26, height: 62)
    private static let dpiButton = CGRect(x: width / 2 - 9, y: 112, width: 18, height: 30)
    private static let forward = CGRect(x: -7, y: 190, width: 14, height: 46)
    private static let back = CGRect(x: -7, y: 244, width: 14, height: 46)

    private static var bodyShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 108, bottomLeadingRadius: 84, bottomTrailingRadius: 84, topTrailingRadius: 108, style: .continuous)
    }
    private static let bodyPath = bodyShape.path(in: CGRect(x: 0, y: 0, width: width, height: height))

    /// Which button is under a point (body coordinates). Small parts win over the big faces they sit on.
    static func hit(_ point: CGPoint) -> String? {
        let slack: CGFloat = 5
        if wheel.insetBy(dx: -slack, dy: -slack).contains(point) { return "middle" }
        if dpiButton.insetBy(dx: -slack, dy: -slack).contains(point) { return "dpi" }
        if forward.insetBy(dx: -slack, dy: -slack).contains(point) { return "forward" }
        if back.insetBy(dx: -slack, dy: -slack).contains(point) { return "back" }
        guard bodyPath.contains(point), point.y < split else { return nil }
        return point.x < width / 2 ? "left" : "right"
    }

    var body: some View {
        let area = CGSize(width: Self.width + Self.margin.width * 2, height: Self.height + Self.margin.height * 2)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [lightsOn ? accent.opacity(0.32) : .clear, .clear], center: .center, startRadius: 0, endRadius: 200))
                .frame(width: 400, height: 400)
                .offset(y: 70)
                .allowsHitTesting(false)
            drawing
                .frame(width: Self.width, height: Self.height)
                .allowsHitTesting(false)
            Color.clear
                .frame(width: area.width, height: area.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = Self.hit(local(point))
                    case .ended: hovered = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in pressed = Self.hit(local(value.location)) }
                    .onEnded { value in
                        pressed = nil
                        if let id = Self.hit(local(value.location)) { onSelect(id) }
                    })
        }
        .frame(width: 420, height: 440)
        .help(hovered.flatMap { id in Self.g203.first { $0.id == id }?.title }.map { Text(LocalizedStringKey($0)) } ?? Text(verbatim: ""))
        .animation(.snappy(duration: 0.16), value: hovered)
        .animation(.snappy(duration: 0.16), value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Mouse illustration"))
        .accessibilityChildren {
            ForEach(Self.g203) { button in
                SwiftUI.Button(LocalizedStringKey(button.title)) { onSelect(button.id) }
                    .accessibilityAddTraits(selected == button.id ? .isSelected : [])
            }
        }
    }

    /// Converts a point of the hit layer to body coordinates.
    private func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - Self.margin.width, y: point.y - Self.margin.height) }

    // MARK: Drawing

    private func tint(_ id: String) -> Color {
        if pressed == id { return accent.opacity(0.50) }
        if selected == id { return accent.opacity(0.38) }
        if hovered == id { return accent.opacity(0.22) }
        return remapped.contains(id) ? accent.opacity(0.12) : .clear
    }

    private var drawing: some View {
        ZStack(alignment: .topLeading) {
            Self.bodyShape.fill(Color.primary.opacity(0.07))
            // Button faces.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(tint("left")).frame(width: Self.width / 2, height: Self.split)
                Rectangle().fill(tint("right")).frame(width: Self.width / 2, height: Self.split).offset(x: Self.width / 2)
                Path { path in
                    path.move(to: CGPoint(x: Self.width / 2, y: 0)); path.addLine(to: CGPoint(x: Self.width / 2, y: Self.split))
                    path.move(to: CGPoint(x: 0, y: Self.split)); path.addLine(to: CGPoint(x: Self.width, y: Self.split))
                }
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .clipShape(Self.bodyShape)
            Self.bodyShape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
            part("middle", Self.wheel, radius: 13, base: Color.primary.opacity(0.55))
            part("dpi", Self.dpiButton, radius: 9, base: Color.primary.opacity(0.30))
            part("forward", Self.forward, radius: 7, base: Color.primary.opacity(0.30))
            part("back", Self.back, radius: 7, base: Color.primary.opacity(0.30))
            Circle().fill(lightsOn ? accent : Color.primary.opacity(0.2)).frame(width: 22, height: 22)
                .shadow(color: lightsOn ? accent.opacity(0.7) : .clear, radius: 10)
                .offset(x: Self.width / 2 - 11, y: 260)
                .animation(.smooth(duration: 0.4), value: accent)
            if let dpi {
                Text(verbatim: "\(dpi)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.width).offset(y: 312)
                    .contentTransition(.numericText(value: Double(dpi)))
            }
        }
    }

    private func part(_ id: String, _ rect: CGRect, radius: CGFloat, base: Color) -> some View {
        let active = selected == id || hovered == id || pressed == id
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(active ? accent.opacity(selected == id || pressed == id ? 0.95 : 0.7) : base)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.8))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}
