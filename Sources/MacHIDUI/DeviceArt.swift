import SwiftUI
import MacHIDDomain

/// Generic device silhouettes. A definition can later ship its own artwork; until then every device
/// of a category gets the same drawing, tinted with its current lighting color (SPEC §19.5 fallback).
struct DeviceArt: View {
    let category: DeviceCategory
    var accent: Color
    var artwork: LoadedArtwork?
    /// Capability ids that have controls; only their hotspots are interactive.
    var interactive: Set<String> = []
    var onHotspot: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.35))
                .blur(radius: 60)
                .frame(width: 260, height: 260)
            if let artwork {
                ArtworkView(artwork: artwork, accent: accent, interactive: interactive, onHotspot: onHotspot)
            } else {
            switch category {
            case .mouse: MouseShape(accent: accent)
            case .keyboard: KeyboardShape(accent: accent)
            case .camera: CameraShape(accent: accent)
            default: Image(systemName: Titles.symbol(for: category)).font(.system(size: 90, weight: .thin)).foregroundStyle(accent)
            }
            }
        }
        .modifier(IdleFloat(enabled: !reduceMotion))
        .frame(height: 240)
        .animation(.smooth(duration: 0.5), value: accent)
    }
}

private struct MouseShape: View {
    var accent: Color
    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 80, bottomLeadingRadius: 70, bottomTrailingRadius: 70, topTrailingRadius: 80, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 80, bottomLeadingRadius: 70, bottomTrailingRadius: 70, topTrailingRadius: 80, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .frame(width: 130, height: 200)
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 70).padding(.top, 2)
            Capsule().fill(accent).frame(width: 10, height: 34).padding(.top, 34).shadow(color: accent, radius: 10)
            Capsule().fill(accent.opacity(0.9)).frame(width: 60, height: 5).padding(.top, 150).shadow(color: accent, radius: 8)
        }
    }
}

private struct KeyboardShape: View {
    var accent: Color
    var body: some View {
        let columns = 12
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .frame(width: 400, height: 170)
            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<(row == 3 ? 6 : columns), id: \.self) { column in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(accent.opacity(0.75))
                                .frame(width: row == 3 && column == 2 ? 120 : 22, height: 22)
                                .shadow(color: accent.opacity(0.8), radius: 5)
                        }
                    }
                }
            }
        }
    }
}

private struct CameraShape: View {
    var accent: Color
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .frame(width: 230, height: 120)
            Circle().fill(.black.opacity(0.6)).frame(width: 84, height: 84)
            Circle().strokeBorder(accent.opacity(0.9), lineWidth: 3).frame(width: 84, height: 84).shadow(color: accent, radius: 8)
            Circle().fill(accent.opacity(0.5)).frame(width: 30, height: 30)
        }
    }
}

/// A slow, barely visible bob so the device feels alive; off with "Reduce motion".
private struct IdleFloat: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                content.offset(y: sin(t * 0.9) * 4).rotationEffect(.degrees(sin(t * 0.6) * 0.6))
            }
        } else {
            content
        }
    }
}


/// A device drawing with its hotspots: faint rings that light up on hover and open that capability's controls.
private struct ArtworkView: View {
    let artwork: LoadedArtwork
    let accent: Color
    let interactive: Set<String>
    let onHotspot: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        GeometryReader { proxy in
            let box = artwork.layout.viewBox
            let scale = min(proxy.size.width / box.width, proxy.size.height / box.height)
            let origin = CGPoint(x: (proxy.size.width - box.width * scale) / 2, y: (proxy.size.height - box.height * scale) / 2)
            ZStack(alignment: .topLeading) {
                Image(nsImage: artwork.image).resizable().interpolation(.high)
                    .frame(width: box.width * scale, height: box.height * scale)
                    .offset(x: origin.x, y: origin.y)
                ForEach(Array(artwork.layout.hotspots.enumerated()), id: \.offset) { _, hotspot in
                    if interactive.contains(hotspot.capabilityID) {
                        let rect = CGRect(x: origin.x + (hotspot.frame.x - box.x) * scale, y: origin.y + (hotspot.frame.y - box.y) * scale,
                                          width: hotspot.frame.width * scale, height: hotspot.frame.height * scale)
                        HotspotShape(hotspot: hotspot, scale: scale)
                            .stroke(accent.opacity(hovered == hotspot.capabilityID ? 0.95 : 0.35), lineWidth: hovered == hotspot.capabilityID ? 2.5 : 1.5)
                            .background(HotspotShape(hotspot: hotspot, scale: scale).fill(accent.opacity(hovered == hotspot.capabilityID ? 0.22 : 0.07)))
                            .shadow(color: accent.opacity(hovered == hotspot.capabilityID ? 0.9 : 0), radius: 8)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .contentShape(HotspotShape(hotspot: hotspot, scale: scale))
                            .onHover { hovered = $0 ? hotspot.capabilityID : (hovered == hotspot.capabilityID ? nil : hovered) }
                            .onTapGesture { onHotspot(hotspot.capabilityID) }
                            .animation(.snappy(duration: 0.2), value: hovered)
                            .accessibilityElement()
                            .accessibilityLabel(Titles.control(hotspot.capabilityID))
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }
}

private struct HotspotShape: Shape {
    let hotspot: ArtworkHotspot
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        switch hotspot.shape {
        case .ellipse: Path(ellipseIn: rect)
        case .rect(let radius): Path(roundedRect: rect, cornerRadius: CGFloat(radius) * scale, style: .continuous)
        }
    }
}
