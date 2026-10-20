import SwiftUI
import MacHIDDomain

/// Lighting: a mode, then only the options that mode (and this device) understands: colors, speed, brightness,
/// direction, waveform. What is offered comes from the definition, never from the device's name.
struct LightingControl: View {
    let modes: [String]
    let zone: LightingZone?
    let value: SettingValue?
    let onChange: (SettingValue) -> Void

    private var effect: LightingEffect? { if case .effect(let e)? = value { e } else { nil } }
    private var mode: String { LightingModes.mode(of: value) ?? modes.first ?? "static" }
    private var options: LightingModeOptions? { zone?.modeOptions?[mode] }

    private var color: Color {
        switch value {
        case .color(let rgb)?: rgb.color
        case .effect(let effect)? where effect.color != nil: effect.color!.color
        default: .white
        }
    }
    private var secondColor: Color? { effect?.secondColor?.color }
    private var usesColor: Bool { LightingModes.usesColor(mode) || (options?.colorsMax ?? 0) >= 1 }
    private var colorIsOptional: Bool { (options?.colorsMin ?? 1) == 0 }
    private var hasColor: Bool { !(colorIsOptional && effect != nil && effect?.color == nil) }
    private var allowsSecondColor: Bool { (options?.colorsMax ?? 1) >= 2 }
    private var brightness: Int { effect?.brightness ?? 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker
            if mode != "off" {
                if usesColor { colorSection }
                if let range = speedRange { speedSlider(range) }
                if zone?.brightness == true { brightnessSlider }
                if let directions = options?.directions, directions.count > 1 { directionPicker(directions) }
                if mode == "breathing", let waveforms = zone?.waveforms, !waveforms.isEmpty { waveformPicker(waveforms) }
            }
        }
        .motion(\.snappy, value: mode)
    }

    // MARK: Pieces

    private var modePicker: some View {
        FlowRow(spacing: 8) {
            ForEach(modes, id: \.self) { candidate in
                Button { select(candidate) } label: { Titles.lightingMode(candidate) }
                    .buttonStyle(PillButtonStyle(selected: candidate == mode))
                    .accessibilityAddTraits(candidate == mode ? .isSelected : [])
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if colorIsOptional {
                Toggle(isOn: Binding(get: { hasColor }, set: { on in build(color: on ? color : nil, second: nil) })) { Text("Choose colors").font(.callout) }
                    .toggleStyle(.switch)
            }
            if hasColor {
                swatchRow(selected: color, title: allowsSecondColor ? Text("Color") : nil) { build(color: $0, second: secondColor) }
                if allowsSecondColor {
                    Toggle(isOn: Binding(get: { secondColor != nil }, set: { on in build(color: color, second: on ? .white : nil) })) {
                        Text("Second color").font(.callout)
                    }
                    .toggleStyle(.switch)
                    if let second = secondColor { swatchRow(selected: second, title: nil) { build(color: color, second: $0) } }
                }
            }
        }
    }

    private func swatchRow(selected: Color, title: Text?, pick: @escaping (Color) -> Void) -> some View {
        ColorField(selected: RGBColor(selected), title: title) { pick($0.color) }
    }

    /// Discrete speed (Razer) or a period in milliseconds (Logitech); the slider always reads slow to fast.
    private enum SpeedRange { case steps(ClosedRange<Int>), period(ClosedRange<Int>) }

    private var speedRange: SpeedRange? {
        if let low = options?.speedMin, let high = options?.speedMax, high > low { return .steps(low...high) }
        if ["cycle", "breathing"].contains(mode), let low = zone?.periodMin, let high = zone?.periodMax, high > low { return .period(low...high) }
        return nil
    }

    private func speedSlider(_ range: SpeedRange) -> some View {
        switch range {
        case .steps(let steps):
            // Speed 1 is the device's own first step; the slider keeps the device's order.
            let current = effect?.speed ?? (steps.lowerBound + steps.upperBound) / 2
            return AnyView(SettingRow(title: Text("Speed")) {
                Slider(value: Binding(get: { Double(current) }, set: { build(speed: Int($0.rounded())) }),
                       in: Double(steps.lowerBound)...Double(steps.upperBound))
            })
        case .period(let period):
            let current = effect?.period ?? 5000
            let slow = period.upperBound, fast = period.lowerBound
            return AnyView(SettingRow(title: Text("Speed")) {
                Slider(value: Binding(get: { Double(slow + fast - min(max(current, fast), slow)) },
                                      set: { build(period: slow + fast - Int($0.rounded())) }),
                       in: Double(fast)...Double(slow))
            })
        }
    }

    private var brightnessSlider: some View {
        SettingRow(title: Text("Brightness"), value: Text(verbatim: "\(brightness)%")) {
            Slider(value: Binding(get: { Double(brightness) }, set: { build(brightness: Int($0.rounded())) }), in: 1...100)
        }
    }

    private func directionPicker(_ directions: [String]) -> some View {
        SettingRow(title: Text("Direction")) {
            Segmented(options: Array(directions.indices), selection: Binding(get: { effect?.direction ?? directions.count - 1 },
                                                                            set: { build(direction: $0) })) { index in
                Titles.direction(directions[index])
            }
        }
    }

    private func waveformPicker(_ waveforms: [String]) -> some View {
        SettingRow(title: Text("Waveform")) {
            Picker("", selection: Binding(get: { effect?.waveform ?? 0 }, set: { build(waveform: $0) })) {
                ForEach(Array(waveforms.enumerated()), id: \.offset) { index, name in Text(verbatim: Titles.humanize(name)).tag(index) }
            }
            .labelsHidden()
        }
    }

    // MARK: Building values

    private func select(_ newMode: String) {
        let previous = effect
        let base = color
        let defaults = zone?.modeOptions?[newMode]
        var speed: Int?
        if let low = defaults?.speedMin, let high = defaults?.speedMax { speed = (low + high) / 2 }
        compose(mode: newMode, color: base, second: previous?.secondColor?.color, period: previous?.period, brightness: previous?.brightness,
                waveform: previous?.waveform, speed: speed, direction: defaults?.directions != nil ? (defaults!.directions!.count - 1) : nil)
    }

    private func build(color: Color?, second: Color?) {
        compose(mode: mode, color: color, second: second, period: effect?.period, brightness: effect?.brightness,
                waveform: effect?.waveform, speed: effect?.speed, direction: effect?.direction)
    }
    private func build(speed: Int) { compose(mode: mode, color: color, second: secondColor, period: effect?.period, brightness: effect?.brightness, waveform: effect?.waveform, speed: speed, direction: effect?.direction) }
    private func build(period: Int) { compose(mode: mode, color: color, second: secondColor, period: period, brightness: effect?.brightness, waveform: effect?.waveform, speed: effect?.speed, direction: effect?.direction) }
    private func build(brightness: Int) { compose(mode: mode, color: color, second: secondColor, period: effect?.period, brightness: brightness, waveform: effect?.waveform, speed: effect?.speed, direction: effect?.direction) }
    private func build(direction: Int) { compose(mode: mode, color: color, second: secondColor, period: effect?.period, brightness: effect?.brightness, waveform: effect?.waveform, speed: effect?.speed, direction: direction) }
    private func build(waveform: Int) { compose(mode: mode, color: color, second: secondColor, period: effect?.period, brightness: effect?.brightness, waveform: waveform, speed: effect?.speed, direction: effect?.direction) }

    private func compose(mode: String, color: Color?, second: Color?, period: Int?, brightness: Int?, waveform: Int?, speed: Int?, direction: Int?) {
        let rgb = color.map { RGBColor($0) }
        switch mode {
        case "off": onChange(.text("off"))
        case "static" where brightness == nil || brightness == 100:
            onChange(.color(rgb ?? RGBColor(r: 255, g: 255, b: 255)))
        default:
            let usesColor = LightingModes.usesColor(mode) || (zone?.modeOptions?[mode]?.colorsMax ?? 0) >= 1
            let needsPeriod = zone?.periodMin != nil && ["cycle", "breathing"].contains(mode)
            onChange(.effect(LightingEffect(mode, color: usesColor ? (rgb ?? (LightingModes.colorIsOptional(mode) ? nil : RGBColor(r: 255, g: 255, b: 255))) : nil,
                                            period: needsPeriod ? (period ?? 5000) : nil,
                                            brightness: zone?.brightness == true ? brightness : nil,
                                            waveform: mode == "breathing" && zone?.waveforms != nil ? (waveform ?? 0) : nil,
                                            speed: zone?.modeOptions?[mode]?.speedMin != nil ? speed : nil,
                                            direction: zone?.modeOptions?[mode]?.directions != nil ? direction : nil,
                                            secondColor: second.map { RGBColor($0) })))
        }
    }
}
