import SwiftUI
import AppKit
import MacHIDDomain

/// The keyboard from above, lit the way the real one is. Effects are simulated from the current setting, so changes
/// can be judged before looking down at the board. Click a key to select it.
struct KeyboardSimView: View {
    let layout: KeyboardLayout
    var effect: SimEffect
    var brightness: Double = 1
    var selected: String?
    var remapped: Set<String> = []
    /// Painting mode: dragging across keys selects each key it touches.
    var dragSelects = false
    var onSelect: (String) -> Void = { _ in }

    @State private var lastDragged: String?
    @State private var hovered: String?
    @State private var flashes: [String: Date] = [:]
    @State private var monitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        GeometryReader { proxy in
            let unit = min((proxy.size.width - 48) / layout.width, 52)
            let boardWidth = layout.width * unit, boardHeight = layout.height * unit
            let origin = CGPoint(x: (proxy.size.width - boardWidth) / 2, y: (proxy.size.height - boardHeight) / 2)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !effect.isAnimated || reduceMotion || activeState == .inactive)) { timeline in
                Canvas { context, size in
                    draw(&context, unit: unit, origin: origin, time: timeline.date)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = key(at: point, unit: unit, origin: origin)?.id
                case .ended: hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let key = key(at: value.location, unit: unit, origin: origin), key.id != lastDragged else { return }
                    if dragSelects || lastDragged == nil { lastDragged = key.id; flashes[key.id] = Date(); onSelect(key.id) }
                }
                .onEnded { _ in lastDragged = nil })
            .overlay(alignment: .topLeading) {
                if let id = hovered, let key = layout.key(id: id) {
                    Text(verbatim: key.label.isEmpty ? "Space" : key.label)
                        .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
                        .flatSurface(cornerRadius: 8)
                        .position(x: origin.x + (key.x + key.width / 2) * unit, y: origin.y + key.y * unit - 14)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 280)
        .onAppear(perform: startMonitor)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Keyboard illustration"))
    }

    private func key(at point: CGPoint, unit: CGFloat, origin: CGPoint) -> KeyboardKey? {
        layout.key(atX: Double((point.x - origin.x) / unit), y: Double((point.y - origin.y) / unit))
    }

    /// Typing inside MacHID's own window lights the keys (reactive effects). Only the key identity is used, and only
    /// for a moment; nothing is stored.
    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if let id = KeyboardKeyCodes.keyID(forCode: Int(event.keyCode)) { flashes[id] = Date() }
            return event
        }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, unit: CGFloat, origin: CGPoint, time: Date) {
        let t = time.timeIntervalSinceReferenceDate
        let gap: CGFloat = max(2, unit * 0.07)
        func rect(_ key: KeyboardKey) -> CGRect {
            CGRect(x: origin.x + key.x * unit + gap / 2, y: origin.y + key.y * unit + gap / 2,
                   width: key.width * unit - gap, height: key.height * unit - gap)
        }
        // Chassis.
        let chassis = CGRect(x: origin.x - 12, y: origin.y - 12, width: layout.width * unit + 24, height: layout.height * unit + 24)
        context.fill(Path(roundedRect: chassis, cornerRadius: 22, style: .continuous), with: .color(.white.opacity(0.06)))
        context.stroke(Path(roundedRect: chassis, cornerRadius: 22, style: .continuous), with: .color(.white.opacity(0.22)), lineWidth: 1)

        let colors: [String: Color] = Dictionary(uniqueKeysWithValues: layout.keys.map { ($0.id, litColor(for: $0, time: t)) })
        // Glow under the keys: one blurred layer for the whole board.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: unit * 0.28))
            for key in layout.keys {
                layer.fill(Path(roundedRect: rect(key).insetBy(dx: 1, dy: 1), cornerRadius: unit * 0.18, style: .continuous),
                           with: .color((colors[key.id] ?? .clear).opacity(0.55 * brightness)))
            }
        }
        for key in layout.keys {
            let frame = rect(key)
            let path = Path(roundedRect: frame, cornerRadius: unit * 0.16, style: .continuous)
            let lit = colors[key.id] ?? .clear
            let isSelected = selected == key.id
            context.fill(path, with: .color(Color(white: 0.13, opacity: 0.85)))
            context.fill(path, with: .color(lit.opacity(0.78 * brightness)))
            // A soft highlight on the top edge gives the keycap its shape.
            context.fill(Path(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height * 0.45),
                              cornerRadius: unit * 0.16, style: .continuous), with: .linearGradient(
                                Gradient(colors: [.white.opacity(0.22), .clear]), startPoint: CGPoint(x: frame.midX, y: frame.minY),
                                endPoint: CGPoint(x: frame.midX, y: frame.maxY)))
            context.stroke(path, with: .color(isSelected ? .white : .white.opacity(hovered == key.id ? 0.7 : 0.25)), lineWidth: isSelected ? 2 : 1)
            if !key.label.isEmpty {
                let text = context.resolve(Text(verbatim: key.label).font(.system(size: max(8, unit * (key.label.count > 2 ? 0.22 : 0.3)), weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9)))
                context.draw(text, at: CGPoint(x: frame.midX, y: frame.midY), anchor: .center)
            }
            if remapped.contains(key.id) {
                context.fill(Path(ellipseIn: CGRect(x: frame.maxX - 8, y: frame.minY + 3, width: 5, height: 5)), with: .color(.white))
            }
        }
    }

    private func litColor(for key: KeyboardKey, time t: TimeInterval) -> Color {
        let flash = flashes[key.id].map { max(0, 1 - Date().timeIntervalSince($0) / 0.7) } ?? 0
        return effect.color(for: key, layout: layout, time: t, flash: flash)
    }
}

/// What the keyboard is doing, reduced to what the simulation needs.
struct SimEffect: Equatable {
    enum Mode: Equatable { case off, solid, spectrum, wave, breathing, reactive, starlight, frame }
    var mode: Mode = .solid
    var color: Color = .white
    var secondColor: Color?
    var speed: Double = 1
    var reversed = false
    var frame: [String: Color] = [:]   // "row,col" -> color

    var isAnimated: Bool { [.spectrum, .wave, .breathing, .reactive, .starlight].contains(mode) }

    /// Builds the simulation of a stored lighting value.
    static func from(_ value: SettingValue?, frame: [KeyColor]? = nil) -> SimEffect {
        var sim = SimEffect()
        switch value {
        case .color(let c)?: sim.color = c.color
        case .text("off")?: sim.mode = .off
        case .effect(let e)?:
            if let c = e.color { sim.color = c.color }
            sim.secondColor = e.secondColor?.color
            sim.reversed = (e.direction ?? 0) == 1
            switch e.effect {
            case "spectrum", "cycle": sim.mode = .spectrum
            case "wave": sim.mode = .wave
            case "breathing": sim.mode = .breathing
            case "reactive": sim.mode = .reactive
            case "starlight": sim.mode = .starlight
            case "custom", "frame": sim.mode = .frame
            case "off": sim.mode = .off
            default: sim.mode = .solid
            }
            if let speed = e.speed { sim.speed = 0.5 + Double(speed) * 0.4 }
            else if let period = e.period, period > 0 { sim.speed = 5000.0 / Double(period) }
        default: break
        }
        if let frame {
            sim.mode = .frame
            sim.frame = Dictionary(uniqueKeysWithValues: frame.map { ("\($0.row),\($0.col)", $0.color.color) })
        }
        return sim
    }

    func color(for key: KeyboardKey, layout: KeyboardLayout, time t: TimeInterval, flash: Double) -> Color {
        let x = key.x / max(layout.width, 1)
        switch mode {
        case .off: return .clear
        case .solid: return color
        case .spectrum: return Color(hue: (t * 0.12 * speed).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1)
        case .wave:
            let phase = (reversed ? 1 : -1) * t * 0.22 * speed + x
            return Color(hue: phase - floor(phase), saturation: 0.85, brightness: 1)
        case .breathing:
            let level = 0.12 + 0.88 * (0.5 + 0.5 * sin(t * 1.6 * speed))
            return color.opacity(level)
        case .reactive:
            return flash > 0 ? color.opacity(0.3 + 0.7 * flash) : color.opacity(0.12)
        case .starlight:
            let seed = Double((key.row * 31 + key.col * 17) % 97) / 97
            let phase = (t * 0.25 * speed + seed).truncatingRemainder(dividingBy: 1)
            let glow = pow(max(0, sin(phase * .pi)), 12)
            let star = (secondColor != nil && seed > 0.5) ? secondColor! : color
            return star.opacity(0.08 + 0.92 * glow)
        case .frame:
            return frame["\(key.row),\(key.col)"] ?? .clear
        }
    }
}
