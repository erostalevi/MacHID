import Foundation

/// Rules for the SVG drawings that can come with a device definition (and so with a plugin). They are community
/// drawn files, so only plain vector shapes are accepted: no scripts, no pictures, no links, no external references.
public enum SVGSafety {
    public static let maxBytes = 200 * 1024

    private static let allowedElements: Set<String> = [
        "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "title", "desc",
        "lineargradient", "radialgradient", "stop", "clippath",
    ]

    /// Problems that make a file unusable. Empty means it is safe to render.
    public static func validate(_ data: Data) -> [String] {
        guard data.count <= maxBytes else { return ["the file is larger than \(maxBytes / 1024) KB"] }
        guard let text = String(data: data, encoding: .utf8) else { return ["the file is not UTF-8 text"] }
        // Entities and processing instructions are how XML files pull in other files or blow up in size.
        let lowered = text.lowercased()
        if lowered.contains("<!doctype") || lowered.contains("<!entity") { return ["DOCTYPE and entity declarations are not allowed"] }
        if lowered.contains("<?xml-stylesheet") { return ["stylesheet references are not allowed"] }

        let inspector = Inspector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = inspector
        guard parser.parse() else { return ["not well-formed XML"] }
        var issues = inspector.issues
        if !inspector.sawRoot { issues.append("the root element must be <svg>") }
        return Array(issues.prefix(5))
    }

    private final class Inspector: NSObject, XMLParserDelegate {
        var issues: [String] = []
        var sawRoot = false
        private var depth = 0
        private var elementCount = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            depth += 1
            elementCount += 1
            let name = elementName.lowercased()
            if depth == 1 { sawRoot = name == "svg" }
            if depth > 24 || elementCount > 4000 { issues.append("the drawing is too deeply nested or has too many elements"); parser.abortParsing(); return }
            if !SVGSafety.allowedElements.contains(name) { issues.append("element <\(elementName)> is not allowed") }
            for (key, value) in attributes {
                let attribute = key.lowercased(), content = value.lowercased()
                if attribute.hasPrefix("on") { issues.append("event attribute '\(key)' is not allowed") }
                if attribute == "href" || attribute.hasSuffix(":href") {
                    // Only references to a shape or gradient inside the same file.
                    if !value.hasPrefix("#") { issues.append("external reference in '\(key)' is not allowed") }
                }
                if content.contains("url(") && !content.contains("url(#") { issues.append("external url() in '\(key)' is not allowed") }
                if content.contains("javascript:") || content.contains("@import") || content.contains("data:") { issues.append("'\(key)' contains forbidden content") }
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    }
}

/// A rectangle in the drawing's own coordinates (the domain stays free of graphics frameworks).
public struct ArtworkRect: Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A point of interest in a drawing: clicking it opens the controls of the capability it is named after.
public struct ArtworkHotspot: Equatable, Sendable {
    public enum Shape: Equatable, Sendable { case rect(cornerRadius: Double), ellipse }

    public let capabilityID: String
    /// In the drawing's own coordinates.
    public let frame: ArtworkRect
    public let shape: Shape
}

public struct ArtworkLayout: Equatable, Sendable {
    public let viewBox: ArtworkRect
    public let hotspots: [ArtworkHotspot]

    /// Reads the view box and the hotspots (`rect`, `circle` or `ellipse` elements whose id is `hotspot-<capability>`).
    /// Hotspots must be plain shapes outside any transform, so their numbers are already in drawing coordinates.
    public static func parse(_ data: Data) -> ArtworkLayout? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let box = reader.viewBox, box.width > 0, box.height > 0 else { return nil }
        return ArtworkLayout(viewBox: box, hotspots: reader.hotspots)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var viewBox: ArtworkRect?
        var hotspots: [ArtworkHotspot] = []
        private var transformDepth = 0
        private var stack: [Bool] = []          // for each open element, whether it opened a transform

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            let opensTransform = attributes["transform"] != nil
            stack.append(opensTransform)
            if opensTransform { transformDepth += 1 }
            let name = elementName.lowercased()
            if name == "svg", viewBox == nil {
                if let raw = attributes["viewBox"] {
                    let numbers = raw.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                    if numbers.count == 4 { viewBox = ArtworkRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
                } else if let width = attributes["width"].flatMap(Double.init), let height = attributes["height"].flatMap(Double.init) {
                    viewBox = ArtworkRect(x: 0, y: 0, width: width, height: height)
                }
            }
            guard transformDepth == 0 || (transformDepth == 1 && opensTransform == false && false),
                  let id = attributes["id"], id.hasPrefix("hotspot-"), id.count > "hotspot-".count else { return }
            let capability = String(id.dropFirst("hotspot-".count))
            func number(_ key: String) -> Double { attributes[key].flatMap(Double.init) ?? 0 }
            switch name {
            case "rect":
                hotspots.append(ArtworkHotspot(capabilityID: capability, frame: ArtworkRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                                               shape: .rect(cornerRadius: max(number("rx"), number("ry")))))
            case "circle":
                let r = number("r")
                hotspots.append(ArtworkHotspot(capabilityID: capability, frame: ArtworkRect(x: number("cx") - r, y: number("cy") - r, width: 2 * r, height: 2 * r), shape: .ellipse))
            case "ellipse":
                let rx = number("rx"), ry = number("ry")
                hotspots.append(ArtworkHotspot(capabilityID: capability, frame: ArtworkRect(x: number("cx") - rx, y: number("cy") - ry, width: 2 * rx, height: 2 * ry), shape: .ellipse))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if stack.popLast() == true { transformDepth -= 1 }
        }
    }
}
