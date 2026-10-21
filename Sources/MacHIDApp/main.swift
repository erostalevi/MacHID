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
    @State private var scenes: LightingScenesController
    @State private var globalLight: GlobalLightController

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        _plugins = State(initialValue: PluginsModel.live(app: model))
        let scenes = LightingScenesController(model: model)
        _scenes = State(initialValue: scenes)
        _globalLight = State(initialValue: GlobalLightController(model: model, scenes: scenes))
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
                    remap.onSwitchProfile = { [model] id in Task { await model.applyProfileToAll(id) } }
                    remap.onCycleProfile = { [model] step in Task { await model.cycleProfiles(step: step) } }
                    Task {
                        await remap.load()
                        await scenes.load()
                        remap.onShiftModesChanged = { [scenes] modes in Task { @MainActor in scenes.modesChanged(modes) } }
                    }
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
            MainWindowView(model: model, remap: remap, scenes: scenes)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(model: model, remap: remap, plugins: plugins, updater: updater, globalLight: globalLight)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Tab") {
                ForEach(0..<3, id: \.self) { index in
                    Button(model.sectionTitle(at: index)) {
                        withAnimation(.snappy) { model.selectSection(at: index) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(index >= model.availableTabs.count)
                }
            }
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
