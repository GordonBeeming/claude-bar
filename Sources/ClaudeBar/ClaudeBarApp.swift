import AppKit
import SwiftUI

@main
struct ClaudeBarApp: App {
    @State private var model = UsageViewModel()
    @State private var settings = AppSettings()
    @State private var celebrations = CelebrationController()

    init() {
        // Backstop for `swift run`: there's no Info.plist LSUIElement in that context
        // to hide the Dock icon. The packaged .app sets LSUIElement instead, making
        // this a no-op there.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(model: model, settings: settings)
        } label: {
            MenuBarLabelView(model: model, settings: settings, celebrations: celebrations)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, model: model)
        }
    }
}
