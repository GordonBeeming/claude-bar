import AppKit
import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: UsageViewModel
    @Bindable var login: OAuthLoginController

    @State private var pastedCode = ""
    @State private var telemetryFolderError: String?

    // Codes are pasted from a web page and often carry a trailing newline, which makes the
    // single-line field wrap to a second line. Strip whitespace as it's set — a valid code
    // never contains any — so the field stays on one line.
    private var codeBinding: Binding<String> {
        Binding(
            get: { pastedCode },
            set: { pastedCode = $0.filter { !$0.isWhitespace } }
        )
    }

    var body: some View {
        Form {
            Section("Usage data source") {
                Picker("Token from", selection: $settings.credentialSource) {
                    ForEach(CredentialSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }

                if settings.credentialSource == .selfContained {
                    signInControls
                    Text("Signs in with its own token, so macOS stops re-asking for Keychain access every time Claude Code rotates its token. Falls back to Claude Code's token if this sign-in ever fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reads Claude Code's Keychain token. macOS re-asks for access whenever Claude Code rotates it — switch to self-contained sign-in to stop that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Usage colours") {
                Toggle("Use Claude's severity levels", isOn: $settings.useClaudeSeverity)

                if !settings.useClaudeSeverity {
                    ThresholdBarView(
                        warningPercent: $settings.warningThresholdPercent,
                        criticalPercent: $settings.criticalThresholdPercent
                    )
                    .padding(.vertical, 4)

                    Text("Drag the splitters: blue is fine, orange from the warning threshold, red from the critical one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu bar") {
                Picker("Percentage", selection: menuBarPercentageSelection) {
                    Text("Highest").tag(MenuBarPercentageSelection.highest)
                    ForEach(model.limits, id: \.selectionKey) { limit in
                        Text(LimitPresentation.displayName(for: limit))
                            .tag(MenuBarPercentageSelection.limit(limit.selectionKey))
                    }
                }

                Text("If the selected percentage isn't available, ClaudeBar shows the highest percentage instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("⛽ Fuel tank mode", isOn: $settings.fuelTankMode)

                Text("Show fuel remaining instead of usage consumed: every percentage and bar starts full and drains toward empty as you burn through a limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show 🔥 when burning over pace", isOn: $settings.showMenuBarFlame)

                Text("The flame appears next to the percentage when a limit burns faster than its window's steady pace. Weekly (all models) turns a deeper red; the session and model-scoped windows stay orange.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Celebrations") {
                Toggle("Enable celebrations", isOn: $settings.celebrationsEnabled)

                if settings.celebrationsEnabled {
                    ForEach(CelebrationTrigger.allCases, id: \.self) { trigger in
                        celebrationRow(trigger)
                    }
                } else {
                    Text("Play a full-screen reaction when a usage window resets or your weekly burns over pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Telemetry") {
                Toggle("Record usage history", isOn: $settings.telemetryEnabled)

                if settings.telemetryEnabled {
                    Picker("Every", selection: $settings.telemetryIntervalMinutes) {
                        ForEach(AppSettings.telemetryIntervalChoices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }

                    Picker("Keep", selection: $settings.telemetryRetentionDays) {
                        ForEach(AppSettings.telemetryRetentionChoices, id: \.self) { days in
                            Text(retentionLabel(days)).tag(days)
                        }
                    }

                    LabeledContent("Folder") {
                        Text(abbreviatedPath(settings.telemetryDirectory))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Spacer()
                        Button("Choose…") { chooseTelemetryFolder() }
                        Button("Show in Finder") { showTelemetryFolder() }
                        if settings.telemetryDirectory != TelemetryConfig.defaultDirectory {
                            Button("Use default") { settings.telemetryDirectory = TelemetryConfig.defaultDirectory }
                        }
                    }

                    if let telemetryFolderError {
                        Text(telemetryFolderError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Text("Writes your limits, Claude Code token counts, extra usage, guest passes and credit offers as OpenTelemetry (OTLP JSON) files you can chart or feed to a Collector. Nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                    .help(model.launchAtLoginAvailable ? "" : "Available when installed as ClaudeBar.app")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case AppSettings.telemetryRetentionForever: "Forever"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    private func chooseTelemetryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = settings.telemetryDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        telemetryFolderError = nil
        settings.telemetryDirectory = url
    }

    private func showTelemetryFolder() {
        let url = settings.telemetryDirectory
        do {
            // The folder is only created by the first stamp; make it now so Finder has
            // something to open straight after switching telemetry on.
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            telemetryFolderError = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            telemetryFolderError = "Couldn't open the folder: \(error.localizedDescription)"
        }
    }

    private var menuBarPercentageSelection: Binding<MenuBarPercentageSelection> {
        Binding(
            get: {
                guard
                    let selectedKey = settings.menuBarPercentageSelection.limitSelectionKey,
                    model.limits.contains(where: { $0.selectionKey == selectedKey })
                else {
                    return .highest
                }
                return .limit(selectedKey)
            },
            set: { settings.menuBarPercentageSelection = $0 }
        )
    }

    @ViewBuilder
    private var signInControls: some View {
        switch login.phase {
        case .signedOut:
            Button("Sign in with Claude…") { login.startSignIn() }

        case .awaitingCode:
            VStack(alignment: .leading, spacing: 8) {
                Text("A browser window opened. Approve access, then paste the code it shows here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Paste code", text: codeBinding)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                    Button("Submit") {
                        let code = pastedCode
                        pastedCode = ""
                        Task { await login.submitCode(code) }
                    }
                    .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

        case .exchanging:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Signing in…")
            }

        case .signedIn(let expiresAt):
            HStack {
                Label("Signed in", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Sign out") { login.signOut() }
            }
            Text("Token valid until \(expiresAt.formatted(date: .abbreviated, time: .shortened)); it refreshes automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)

                // Keep the paste field while a flow is still in-air (e.g. a 429) so the user
                // can retry a fresh code without reopening the browser; otherwise just offer
                // to start over.
                if login.hasPendingSignIn {
                    HStack {
                        TextField("Paste code", text: codeBinding)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1)
                        Button("Submit") {
                            let code = pastedCode
                            pastedCode = ""
                            Task { await login.submitCode(code) }
                        }
                        .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button("Restart browser sign-in") { login.startSignIn() }
                } else {
                    Button("Try again") { login.startSignIn() }
                }
            }
        }
    }

    @ViewBuilder
    private func celebrationRow(_ trigger: CelebrationTrigger) -> some View {
        let enabled = Binding(
            get: { settings.celebrationEnabled(for: trigger) },
            set: { settings.setCelebrationEnabled($0, for: trigger) }
        )
        let reaction = Binding(
            get: { settings.reaction(for: trigger) },
            set: { settings.setReaction($0, for: trigger) }
        )

        // Wrap in a VStack so the toggle and its effect row read as one grouped-form
        // row on macOS rather than two disjointed rows.
        VStack(alignment: .leading, spacing: 8) {
            Toggle(trigger.displayName, isOn: enabled)

            if enabled.wrappedValue {
                HStack {
                    Picker("Effect", selection: reaction) {
                        ForEach(ReactionChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Button("Test") { model.previewCelebration(reaction.wrappedValue) }
                }
                .padding(.leading, 16)
            }
        }
    }
}
