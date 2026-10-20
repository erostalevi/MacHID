import AppKit
import SwiftUI
import MacHIDUI

/// Keeps the app alive in the menu bar (no Dock icon) and reopens the window when the user launches
/// MacHID again, for example from Spotlight.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { onReopen?() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MacHIDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var remap = RemapController.live()
    @State private var plugins: PluginsModel
    @State private var updater = UpdaterModel()

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        _plugins = State(initialValue: PluginsModel.live(app: model))
    }
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(model: model, remap: remap, plugins: plugins)
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .task {
                    model.openMainWindow = {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    delegate.onReopen = model.openMainWindow
                    model.start()
                    Task { await remap.load() }
                    Task {
                        await plugins.load()
                        model.onDevicesChanged = { [plugins] in await plugins.devicesChanged() }
                        plugins.startChecking()
                    }
                    // Opened by the user (not by a login item): show the window right away.
                    if !CommandLine.arguments.contains("--background") { model.openMainWindow?() }
                }
        }
        .menuBarExtraStyle(.window)

        Window("MacHID", id: "main") {
            MainWindowView(model: model, remap: remap)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 660)

        Window("Settings", id: "settings") {
            SettingsView(model: model, remap: remap, plugins: plugins, updater: updater)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 620)
        .commands {
            CommandMenu("Device") {
                Button("Next Device") { withAnimation(.smooth) { model.selectNextDevice(offset: 1) } }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Device") { withAnimation(.smooth) { model.selectNextDevice(offset: -1) } }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
    }
}

MacHIDApp.main()
