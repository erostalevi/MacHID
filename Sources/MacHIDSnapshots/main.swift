import AppKit
import SwiftUI
import MacHIDUI

// Renders the app's views to PNG files for design review, without opening any window or reading the screen.
//   MacHIDSnapshots <output-dir> [definitions-dir]
/// Draws the view through an AppKit hosting view in a window that is never shown, so controls such as menus,
/// sliders and glass groups are rendered like in the real app. Nothing appears on screen.
@MainActor
func render<V: View>(_ view: V, size: CGSize, to url: URL, dark: Bool = false) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))   // let SwiftUI settle
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("failed: \(url.lastPathComponent)"); return }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { print("failed: \(url.lastPathComponent)"); return }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

@MainActor
func run() {
    let args = CommandLine.arguments
    guard args.count >= 2 else { print("usage: MacHIDSnapshots <output-dir> [definitions-dir]"); exit(2) }
    let out = URL(fileURLWithPath: args[1])
    if args.count >= 3 { setenv("MACHID_DEFINITIONS", args[2], 1) }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    _ = NSApplication.shared
    UserDefaults.standard.set(true, forKey: "onboarding.completed")   // keep the welcome card out of the window renders
    NSApp.setActivationPolicy(.prohibited)
    let backdrop = Color(nsColor: .windowBackgroundColor)
    let remapForWindows = PreviewSupport.remapController()
    struct State { let name: String; let category: DeviceCategory; let section: ControlSection; let input: String?; let perKey: Bool }
    let states = [State(name: "keyboard", category: .keyboard, section: .lighting, input: nil, perKey: false),
                  State(name: "keyboard-perkey", category: .keyboard, section: .lighting, input: nil, perKey: true),
                  State(name: "keyboard-buttons", category: .keyboard, section: .buttons, input: "esc", perKey: false),
                  State(name: "mouse", category: .mouse, section: .lighting, input: nil, perKey: false),
                  State(name: "mouse-buttons", category: .mouse, section: .buttons, input: "back", perKey: false),
                  State(name: "mouse-performance", category: .mouse, section: .performance, input: nil, perKey: false),
                  State(name: "camera", category: .camera, section: .image, input: nil, perKey: false)]
    for state in states {
        let model = PreviewSupport.model(selecting: state.category)
        model.selectedSection = state.section
        model.selectedInput = state.input
        if state.perKey, let id = model.selectedDevice?.id { model.setPerKey(true, for: id) }
        render(MainWindowView(model: model, remap: remapForWindows).background(backdrop), size: CGSize(width: 1020, height: 680), to: out.appendingPathComponent("window-\(state.name).png"))
        render(MainWindowView(model: model, remap: remapForWindows).background(backdrop), size: CGSize(width: 1020, height: 680), to: out.appendingPathComponent("window-\(state.name)-dark.png"), dark: true)
    }
    let model = PreviewSupport.model(selecting: .mouse)
    let remap = PreviewSupport.remapController()
    render(SettingsView(model: model, remap: remap, plugins: PreviewSupport.pluginsModel(), updater: UpdaterModel(infoDictionary: nil)).background(backdrop), size: CGSize(width: 880, height: 640), to: out.appendingPathComponent("settings.png"))
    render(PluginsView(plugins: PreviewSupport.pluginsModel()).background(backdrop), size: CGSize(width: 620, height: 700), to: out.appendingPathComponent("plugins.png"))
    render(RemapView(remap: remap).background(backdrop), size: CGSize(width: 620, height: 560), to: out.appendingPathComponent("remap.png"))
    render(MacrosView(remap: remap).background(backdrop), size: CGSize(width: 620, height: 640), to: out.appendingPathComponent("macros.png"))
    render(ZStack { backdrop; OnboardingView(remap: remap, model: model, finish: {}) }, size: CGSize(width: 620, height: 560), to: out.appendingPathComponent("onboarding.png"))
    render(MenuPanelView(model: model, remap: remap, plugins: PreviewSupport.pluginsModel()).background(backdrop), size: CGSize(width: 316, height: 440), to: out.appendingPathComponent("menu-panel.png"))
}

import MacHIDDomain
MainActor.assumeIsolated { run() }
