import SwiftUI
import MacHIDDomain

/// Generic device silhouettes. A definition can later ship its own artwork; until then every device
/// of a category gets the same drawing, tinted with its current lighting color (SPEC §19.5 fallback).
struct DeviceArt: View {
    let category: DeviceCategory
    var accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.35))
                .blur(radius: 60)
                .frame(width: 260, height: 260)
            switch category {
            case .mouse: MouseShape(accent: accent)
            case .keyboard: KeyboardShape(accent: accent)
            case .camera: CameraShape(accent: accent)
            default: Image(systemName: Titles.symbol(for: category)).font(.system(size: 90, weight: .thin)).foregroundStyle(accent)
            }
        }
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
