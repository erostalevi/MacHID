import SwiftUI
import AppKit
import MacHIDDomain

/// The colors offered as one-tap swatches. They are exact RGB values (not the system's adaptive colors), so what the
/// swatch shows is what the LEDs are told.
enum LEDPalette {
    static let colors: [MacHIDDomain.RGBColor] = [
        .init(r: 255, g: 0, b: 0), .init(r: 255, g: 106, b: 0), .init(r: 255, g: 200, b: 0), .init(r: 0, g: 255, b: 64),
        .init(r: 0, g: 229, b: 255), .init(r: 0, g: 87, b: 255), .init(r: 138, g: 43, b: 255), .init(r: 255, g: 45, b: 170),
        .init(r: 255, g: 255, b: 255),
    ]
}

extension MacHIDDomain.RGBColor {
    /// "FF6A00" (no #, uppercase).
    var hex: String { String(format: "%02X%02X%02X", r, g, b) }

    /// Accepts "FF6A00", "#ff6a00" and the short "F60"; nil for anything else.
    init?(hex text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }
}

/// Swatches, a hex field and the system picker for one color. Every path ends in the same sRGB bytes.
struct ColorField: View {
    var selected: MacHIDDomain.RGBColor
    var title: Text?
    let pick: (MacHIDDomain.RGBColor) -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title?.font(.caption).foregroundStyle(.secondary)
            FlowRow(spacing: 10) {
                ForEach(LEDPalette.colors, id: \.hex) { swatch in
                    Button { pick(swatch) } label: {
                        Circle().fill(swatch.color).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                            .overlay { if swatch == selected { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(swatch.isLight ? .black : .white) } }
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: "#" + swatch.hex))
                    .accessibilityLabel(Text(verbatim: "#" + swatch.hex))
                }
            }
            HStack(spacing: 8) {
                Circle().fill(selected.color).frame(width: 22, height: 22).overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                Text(verbatim: "#").foregroundStyle(.secondary)
                TextField("RRGGBB", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .focused($editing)
                    .frame(width: 74)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .commitsAndResigns(commit)
                    .onChange(of: text) { _, new in
                        // Apply as soon as it is a complete valid value, so typing a color is live.
                        if editing, new.filter(\.isHexDigit).count == 6, let color = MacHIDDomain.RGBColor(hex: new) { pick(color) }
                    }
                    .onChange(of: editing) { _, now in if !now { commit() } }
                    .accessibilityLabel(Text("Hex color"))
                ColorPicker("", selection: Binding(get: { selected.color }, set: { pick(MacHIDDomain.RGBColor($0)) }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick any color")
                Spacer()
            }
        }
        .onAppear { text = selected.hex }
        .onChange(of: selected) { _, new in if !editing { text = new.hex } }
    }

    private func commit() {
        if let color = MacHIDDomain.RGBColor(hex: text) { pick(color) }
        text = selected.hex
    }
}

extension MacHIDDomain.RGBColor {
    /// Rough perceived brightness, to pick a readable checkmark color.
    var isLight: Bool { (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) > 150 }
}
