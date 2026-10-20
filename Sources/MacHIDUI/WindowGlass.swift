import AppKit
import SwiftUI

/// Turns the hosting window into one floating glass panel: no title bar chrome, a transparent window, and a single
/// system glass layer behind the content that shows the desktop and the apps underneath. Liquid Glass on macOS 26+,
/// a behind-window blur before. The system draws it, so it costs nothing per frame and honors "Reduce transparency".
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Anchor: NSView {
        private weak var configured: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            // After SwiftUI has finished setting the window up.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }
                self?.configure(window)
            }
        }

        private func configure(_ window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            guard let content = window.contentView, let frame = content.superview,
                  !frame.subviews.contains(where: { $0.identifier == Self.glassID }) else { return }
            let glass = Self.makeGlass()
            glass.identifier = Self.glassID
            glass.frame = frame.bounds
            glass.autoresizingMask = [.width, .height]
            frame.addSubview(glass, positioned: .below, relativeTo: content)
        }

        private static let glassID = NSUserInterfaceItemIdentifier("machid.window.glass")

        private static func makeGlass() -> NSView {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let view = NSGlassEffectView()
                view.style = .regular
                return view
            }
            #endif
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }
    }
}

extension View {
    /// Makes this view's window a single floating glass panel (see `WindowGlass`).
    func glassPanelWindow() -> some View {
        background(WindowGlass().frame(width: 0, height: 0))
    }
}
