import AppKit
import SwiftUI

@main
struct ClaudeBarApp: App {
    @State private var model = UsageViewModel()

    init() {
        // Backstop for `swift run`: there's no Info.plist LSUIElement in that context
        // to hide the Dock icon. The packaged .app sets LSUIElement instead, making
        // this a no-op there.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(model: model)
        } label: {
            MenuBarLabelView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
