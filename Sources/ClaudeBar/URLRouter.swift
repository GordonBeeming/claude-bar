import AppKit
import ClaudeBarCore
import os

/// Receives `claudebar://` URLs from macOS and turns them into settings changes or the
/// Settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let router = URLRouter()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { router.handle(url) }
    }
}

/// Applies `claudebar://` requests. Any app or web page can open one of these URLs, so a
/// telemetry change is always shown to the person, old value then new, and only applied when
/// they confirm.
@MainActor
final class URLRouter {
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "URLScheme")
    private weak var settings: AppSettings?
    private var openSettingsWindow: (() -> Void)?
    /// URLs that arrive before the menu bar label has appeared (the app was launched by the
    /// URL) wait here, since there are no settings to change yet.
    private var pending: [URL] = []

    /// Idempotent: the label's `.onAppear` can fire more than once.
    func attach(settings: AppSettings, openSettings: @escaping () -> Void) {
        self.openSettingsWindow = openSettings
        guard self.settings == nil else { return }
        self.settings = settings
        let queued = pending
        pending = []
        for url in queued { handle(url) }
    }

    func handle(_ url: URL) {
        guard let settings else {
            pending.append(url)
            return
        }
        let request: ClaudeBarURLRequest
        do {
            request = try ClaudeBarURLRequest.parse(url)
        } catch {
            // The reason can quote a rejected folder path, which can name a person or project.
            logger.notice("rejected claudebar URL: \(error.localizedDescription, privacy: .private)")
            showRejection(error.localizedDescription)
            return
        }
        switch request {
        case .openSettings:
            NSApp.activate(ignoringOtherApps: true)
            openSettingsWindow?()
        case .telemetry(let change):
            confirmAndApply(change, to: settings)
        }
    }

    private func confirmAndApply(_ change: ClaudeBarURLRequest.TelemetryChange, to settings: AppSettings) {
        let lines = Self.changeLines(change, settings: settings)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard !lines.isEmpty else {
            alert.messageText = "Tracking settings are already set"
            alert.informativeText = "A link asked ClaudeBar to change its tracking settings, but they already match what it asked for."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.messageText = "Change ClaudeBar's tracking settings?"
        alert.informativeText = "A link asked ClaudeBar to make these changes:\n\n" + lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            logger.notice("claudebar telemetry change cancelled")
            return
        }
        // Applied straight to settings: they persist to the defaults keys Bar UI reads, and
        // the telemetry controller picks the change up through observation.
        if let folder = change.folder { settings.telemetryDirectory = folder }
        if let retention = change.retentionDays { settings.telemetryRetentionDays = retention }
        if let interval = change.intervalMinutes { settings.telemetryIntervalMinutes = interval }
        if let enabled = change.enabled { settings.telemetryEnabled = enabled }
        logger.notice("claudebar telemetry change applied")
    }

    /// One `Name: old → new` line per setting the request would actually change.
    static func changeLines(_ change: ClaudeBarURLRequest.TelemetryChange, settings: AppSettings) -> [String] {
        var lines: [String] = []
        if let enabled = change.enabled, enabled != settings.telemetryEnabled {
            lines.append("Tracking: \(onOff(settings.telemetryEnabled)) → \(onOff(enabled))")
        }
        if let interval = change.intervalMinutes, interval != settings.telemetryIntervalMinutes {
            lines.append("Interval: \(minutes(settings.telemetryIntervalMinutes)) → \(minutes(interval))")
        }
        if let retention = change.retentionDays, retention != settings.telemetryRetentionDays {
            lines.append("Keep: \(days(settings.telemetryRetentionDays)) → \(days(retention))")
        }
        if let folder = change.folder, folder.standardizedFileURL.path != settings.telemetryDirectory.standardizedFileURL.path {
            lines.append("Folder: \(path(settings.telemetryDirectory)) → \(path(folder))")
        }
        return lines
    }

    private func showRejection(_ reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ClaudeBar ignored a link"
        alert.informativeText = "Nothing was changed. \(reason)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    private static func minutes(_ value: Int) -> String { value == 1 ? "1 min" : "\(value) min" }

    private static func days(_ value: Int) -> String {
        switch value {
        case AppSettings.telemetryRetentionForever: "Forever"
        case 1: "1 day"
        default: "\(value) days"
        }
    }

    private static func path(_ url: URL) -> String {
        ClaudeBarURLRequest.displayPath(url)
    }
}
