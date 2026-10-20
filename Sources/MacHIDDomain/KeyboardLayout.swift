/// One physical key: where it sits on the board (key units) and which cell of the lighting matrix drives it.
public struct KeyboardKey: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// Cell in the custom-frame matrix (`SettingValue.keyFrame` uses the same row and column).
    public let row: Int
    public let col: Int
    /// Geometry in key units (1u = a standard key). Origin is the top-left corner of the board.
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// True when the matrix cell was cross-checked between two independent sources (see the change record M11).
    /// False means it rests on a single source. Nothing here has been verified on hardware yet.
    public let matrixCrossChecked: Bool

    public init(id: String, label: String, row: Int, col: Int, x: Double, y: Double,
                width: Double = 1, height: Double = 1, matrixCrossChecked: Bool = true) {
        self.id = id
        self.label = label
        self.row = row
        self.col = col
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.matrixCrossChecked = matrixCrossChecked
    }
}

/// Pure data describing a keyboard for drawing and for mapping clicks to matrix cells.
public struct KeyboardLayout: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let matrixRows: Int
    public let matrixColumns: Int
    public let keys: [KeyboardKey]

    public init(id: String, name: String, matrixRows: Int, matrixColumns: Int, keys: [KeyboardKey]) {
        self.id = id
        self.name = name
        self.matrixRows = matrixRows
        self.matrixColumns = matrixColumns
        self.keys = keys
    }

    /// Board size in key units.
    public var width: Double { keys.map { $0.x + $0.width }.max() ?? 0 }
    public var height: Double { keys.map { $0.y + $0.height }.max() ?? 0 }

    public func key(row: Int, col: Int) -> KeyboardKey? { keys.first { $0.row == row && $0.col == col } }
    public func key(id: String) -> KeyboardKey? { keys.first { $0.id == id } }

    /// The key under a point given in key units (for hit testing; the UI divides pixels by its unit size).
    public func key(atX x: Double, y: Double) -> KeyboardKey? {
        keys.first { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }
    }

    /// Frame that paints every key of the layout with `color`.
    public func frame(filling color: RGBColor) -> [KeyColor] { keys.map { KeyColor(row: $0.row, col: $0.col, color: color) } }

    /// Razer Huntsman Mini (USB 1532:0257): 61-key 60% ANSI, matrix 5 rows x 15 columns, column 0 unused.
    /// Matrix cells come from Polychromatic's device map `huntsman_mini_en_US.json` (GPL-3.0; evdev code -> [col, row]);
    /// they were compared with OpenRazer's `KEY_MAPPING` (keyboard.py) for the full-size layout. Esc (it sits where the
    /// full-size board has the backtick) and the ANSI backslash have no counterpart there: `matrixCrossChecked` is false.
    /// Key sizes are the standard ANSI 60% sizes (assumed, not measured).
    public static let huntsmanMini: KeyboardLayout = {
        typealias Spec = (id: String, label: String, col: Int, width: Double)
        func make(row: Int, _ specs: [Spec], unchecked: Set<String> = []) -> [KeyboardKey] {
            var x = 0.0
            return specs.map { spec in
                defer { x += spec.width }
                return KeyboardKey(id: spec.id, label: spec.label, row: row, col: spec.col, x: x, y: Double(row),
                                   width: spec.width, matrixCrossChecked: !unchecked.contains(spec.id))
            }
        }
        let row0: [Spec] = [("esc", "Esc", 1, 1)]
            + "1234567890".enumerated().map { (String($1), String($1), $0 + 2, 1.0) }
            + [("minus", "-", 12, 1), ("equal", "=", 13, 1), ("backspace", "Backspace", 14, 2)]
        let row1: [Spec] = [("tab", "Tab", 1, 1.5)]
            + "QWERTYUIOP".enumerated().map { (String($1).lowercased(), String($1), $0 + 2, 1.0) }
            + [("lbracket", "[", 12, 1), ("rbracket", "]", 13, 1), ("backslash", "\\", 14, 1.5)]
        let row2: [Spec] = [("caps", "Caps", 1, 1.75)]
            + "ASDFGHJKL".enumerated().map { (String($1).lowercased(), String($1), $0 + 2, 1.0) }
            + [("semicolon", ";", 11, 1), ("quote", "'", 12, 1), ("enter", "Enter", 14, 2.25)]
        let row3: [Spec] = [("lshift", "Shift", 1, 2.25)]
            + "ZXCVBNM".enumerated().map { (String($1).lowercased(), String($1), $0 + 3, 1.0) }
            + [("comma", ",", 10, 1), ("period", ".", 11, 1), ("slash", "/", 12, 1), ("rshift", "Shift", 14, 2.75)]
        let row4: [Spec] = [("lctrl", "Ctrl", 1, 1.25), ("lsuper", "Super", 2, 1.25), ("lalt", "Alt", 3, 1.25),
                            ("space", "", 7, 6.25), ("ralt", "Alt", 11, 1.25), ("fn", "Fn", 12, 1.25),
                            ("menu", "Menu", 13, 1.25), ("rctrl", "Ctrl", 14, 1.25)]
        return KeyboardLayout(
            id: "razer-huntsman-mini-ansi", name: "Razer Huntsman Mini (ANSI)", matrixRows: 5, matrixColumns: 15,
            keys: make(row: 0, row0, unchecked: ["esc"]) + make(row: 1, row1, unchecked: ["backslash"])
                + make(row: 2, row2) + make(row: 3, row3) + make(row: 4, row4))
    }()
}

extension KeyboardLayout {
    /// The drawing of the keyboard a definition describes, if one exists.
    public static func layout(forDefinitionID id: String?) -> KeyboardLayout? {
        id == "razer-huntsman-mini" ? .huntsmanMini : nil
    }
}
