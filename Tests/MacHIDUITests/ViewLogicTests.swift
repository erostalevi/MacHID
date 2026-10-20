import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDUI

struct ViewLogicTests {
    @Test func hexParsingAcceptsCommonForms() {
        #expect(MacHIDDomain.RGBColor(hex: "FF6A00") == .init(r: 255, g: 106, b: 0))
        #expect(MacHIDDomain.RGBColor(hex: "#ff6a00") == .init(r: 255, g: 106, b: 0))
        #expect(MacHIDDomain.RGBColor(hex: " f60 ") == .init(r: 255, g: 102, b: 0))
        #expect(MacHIDDomain.RGBColor(hex: "GG0000") == nil)
        #expect(MacHIDDomain.RGBColor(hex: "12345") == nil)
        #expect(MacHIDDomain.RGBColor(r: 1, g: 2, b: 255).hex == "0102FF")
    }

    @Test func swatchesAreExactAndRoundTrip() {
        for swatch in LEDPalette.colors { #expect(MacHIDDomain.RGBColor(swatch.color) == swatch, "\(swatch.hex)") }
    }

    @Test func everyMouseButtonHasAHitArea() {
        // Points taken from the middle of each part of the drawing (body coordinates).
        #expect(MouseSimView.hit(CGPoint(x: 55, y: 80)) == "left")
        #expect(MouseSimView.hit(CGPoint(x: 165, y: 80)) == "right")
        #expect(MouseSimView.hit(CGPoint(x: 110, y: 70)) == "middle")
        #expect(MouseSimView.hit(CGPoint(x: 110, y: 127)) == "dpi")
        #expect(MouseSimView.hit(CGPoint(x: 0, y: 213)) == "forward")
        #expect(MouseSimView.hit(CGPoint(x: 0, y: 267)) == "back")
        #expect(MouseSimView.hit(CGPoint(x: 110, y: 300)) == nil)     // palm area: not a button
        #expect(MouseSimView.hit(CGPoint(x: 2, y: 20)) == nil)        // outside the rounded corner
    }
}
