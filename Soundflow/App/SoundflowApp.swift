import SwiftUI

@main
struct SoundflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let model = delegate.model

        Window("Soundflow", id: WindowID.main) {
            MainWindowView()
                .modifier(WindowOpeners())
                .environment(model)
                .sheet(item: Binding(get: { model.multiOutputDraft }, set: { model.multiOutputDraft = $0 })) { draft in
                    MultiOutputEditor(draft: draft).environment(model)
                }
                .sheet(item: Binding(get: { model.profileDraft }, set: { model.profileDraft = $0 })) { draft in
                    ProfileEditor(draft: draft).environment(model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 860)
        .commands { SoundflowCommands(model: model) }

        Window("Настройки", id: WindowID.settings) {
            SettingsView()
                .modifier(WindowOpeners())
                .environment(model)
                .sheet(item: Binding(get: { model.multiOutputDraft }, set: { model.multiOutputDraft = $0 })) { draft in
                    MultiOutputEditor(draft: draft).environment(model)
                }
                .sheet(item: Binding(get: { model.profileDraft }, set: { model.profileDraft = $0 })) { draft in
                    ProfileEditor(draft: draft).environment(model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 660)

        Window("Добро пожаловать", id: WindowID.onboarding) {
            OnboardingView()
                .modifier(WindowOpeners())
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 740, height: 500)

        MenuBarExtra(isInserted: Binding(get: { model.config.prefs.showMenuBarIcon },
                                         set: { model.config.prefs.showMenuBarIcon = $0 })) {
            MenuBarPopover()
                .modifier(WindowOpeners())
                .environment(model)
        } label: {
            MenuBarIcon()
                .modifier(WindowOpeners())
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

enum WindowID {
    static let main = "main"
    static let settings = "settings"
    static let onboarding = "onboarding"
}

/// Gives the model closures that open our windows (SwiftUI only exposes `openWindow` inside views).
private struct WindowOpeners: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.onAppear {
            model.openMainWindow = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.main)
            }
            model.openSettings = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.settings)
            }
            model.openOnboarding = {
                model.onboardingRequested = true
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.onboarding)
            }
            if !model.didHandleLaunch {
                model.didHandleLaunch = true
                if !model.config.prefs.onboardingDone { model.openOnboarding?() }
                #if DEBUG
                model.applyDebugScreen()
                #endif
            }
        }
    }
}

struct SoundflowCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model.openSettings?() }.keyboardShortcut(",")
        }
        CommandMenu("Вид") {
            Button("Список") { model.mode = .list; model.selection = nil }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Карта") { model.mode = .map; model.selection = nil }.keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandMenu("Профили") {
            ForEach(Array(model.config.profiles.enumerated()), id: \.element.id) { index, profile in
                let button = Button(profile.name) { model.profiles.toggle(profile.id) }
                if index < 9 {
                    button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    button
                }
            }
            Divider()
            Button("Выключить профиль") { model.profiles.deactivate() }.disabled(model.config.activeProfileID == nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        // Without a visible main window (e.g. launched at login) still show onboarding on first run.
        if !model.config.prefs.onboardingDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in
                if NSApp.windows.allSatisfy({ !$0.isVisible || $0.className.contains("StatusBar") }) { model.openOnboarding?() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.config.prefs.runInBackground
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openMainWindow?() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
