import AppKit
import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: UsageViewModel
    var login: AccountLoginControllers

    @State private var telemetryFolderError: String?

    var body: some View {
        Form {
            ForEach(model.accounts) { account in
                AccountSettingsSection(
                    account: account,
                    settings: settings,
                    login: login.controller(for: account.account),
                    onIdentityChange: { Task { await model.refreshAll() } },
                    isExtraFolder: settings.extraAccountFolders.contains(account.account.configDir.standardizedFileURL.path),
                    onRemove: {
                        settings.removeExtraAccountFolder(account.account.configDir.standardizedFileURL.path)
                        Task { await model.refreshAll() }
                    }
                )
            }

            Section {
                HStack {
                    Spacer()
                    Button("Add folder…") { chooseAccountFolder() }
                }
                Text("ClaudeBar finds ~/.claude and every ~/.claude-accounts/ folder that holds a .claude.json. Add a Claude Code config folder from anywhere else here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Accounts")
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
                if model.accounts.count > 1 {
                    Picker("Account", selection: menuBarAccountSelection) {
                        Text("Most used").tag(MenuBarAccountSelection.mostUsed)
                        ForEach(model.accounts) { account in
                            Text(account.account.displayName).tag(MenuBarAccountSelection.account(account.id))
                        }
                    }

                    Text("Which account the icon follows. Most used shows whichever account is closest to a limit. A pinned account with no data yet falls back to most used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Percentage", selection: menuBarPercentageSelection) {
                    Text("Highest").tag(MenuBarPercentageSelection.highest)
                    ForEach(menuBarLimitChoices, id: \.selectionKey) { limit in
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
                        ForEach(
                            withCurrent(settings.telemetryIntervalMinutes, in: AppSettings.telemetryIntervalChoices),
                            id: \.self
                        ) { minutes in
                            Text(intervalLabel(minutes)).tag(minutes)
                        }
                    }

                    Picker("Keep", selection: $settings.telemetryRetentionDays) {
                        ForEach(
                            withCurrent(settings.telemetryRetentionDays, in: AppSettings.telemetryRetentionChoices),
                            id: \.self
                        ) { days in
                            Text(retentionLabel(days)).tag(days)
                        }
                    }
                }

                // Shown while off too, so the folder can be picked before the first recording.
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

                Text("Writes your limits, Claude Code token counts, extra usage, guest passes and credit offers as OpenTelemetry (OTLP JSON) files you can chart or feed to a Collector. ClaudeBar never uploads them. The default folder is in Application Support and stays on this Mac, but a folder you choose that syncs (Documents with iCloud, say) will copy them like any other file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                    .help(model.launchAtLoginAvailable ? "" : "Available when installed as ClaudeBar.app")
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(AppVersion.currentDisplay)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }

    /// One entry per limit key across all accounts, so the same limit isn't listed twice.
    private var menuBarLimitChoices: [UsageLimit] {
        var seen: Set<String> = []
        return model.allLimits.filter { seen.insert($0.selectionKey).inserted }
    }

    private func chooseAccountFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a Claude Code config folder (the CLAUDE_CONFIG_DIR of another account)."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.addExtraAccountFolder(url)
        Task { await model.refreshAll() }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The presets, plus the current value when it isn't one (set through `claudebar://`), so
    /// the picker always shows what's actually in effect.
    private func withCurrent(_ current: Int, in presets: [Int]) -> [Int] {
        guard !presets.contains(current) else { return presets }
        // Forever (0) sorts last in the retention presets, so slot a custom value in before it.
        let forever = presets.last == AppSettings.telemetryRetentionForever ? [AppSettings.telemetryRetentionForever] : []
        let finite = presets.filter { forever.isEmpty || $0 != AppSettings.telemetryRetentionForever }
        return (finite + [current]).sorted() + forever
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case AppSettings.telemetryRetentionForever: "Forever"
        case 1: "1 day"
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
            try FileTelemetrySink.createFolderIfNeeded(url)
            telemetryFolderError = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            telemetryFolderError = "Couldn't open the folder: \(error.localizedDescription)"
        }
    }

    private var menuBarAccountSelection: Binding<MenuBarAccountSelection> {
        Binding(
            get: {
                guard case let .account(id) = settings.menuBarAccountSelection,
                      model.account(withID: id) != nil else {
                    return .mostUsed
                }
                return settings.menuBarAccountSelection
            },
            set: { settings.menuBarAccountSelection = $0 }
        )
    }

    private var menuBarPercentageSelection: Binding<MenuBarPercentageSelection> {
        Binding(
            get: {
                guard
                    let selectedKey = settings.menuBarPercentageSelection.limitSelectionKey,
                    model.allLimits.contains(where: { $0.selectionKey == selectedKey })
                else {
                    return .highest
                }
                return .limit(selectedKey)
            },
            set: { settings.menuBarPercentageSelection = $0 }
        )
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

/// One account's Settings: who it is, where its token comes from, and sign-in when that is
/// ClaudeBar's own.
private struct AccountSettingsSection: View {
    let account: AccountUsageModel
    @Bindable var settings: AppSettings
    @Bindable var login: OAuthLoginController
    /// Signing in or out, or switching source, changes who the account is, so the list is
    /// rediscovered at once rather than at the next poll.
    let onIdentityChange: () -> Void
    let isExtraFolder: Bool
    let onRemove: () -> Void

    @State private var pastedCode = ""

    // Codes are pasted from a web page and often carry a trailing newline, which makes the
    // single-line field wrap to a second line. Strip whitespace as it's set — a valid code
    // never contains any — so the field stays on one line.
    private var codeBinding: Binding<String> {
        Binding(
            get: { pastedCode },
            set: { pastedCode = $0.filter { !$0.isWhitespace } }
        )
    }

    private var source: Binding<CredentialSource> {
        Binding(
            get: { settings.credentialSource(for: account.id) },
            set: { settings.setCredentialSource($0, for: account.id) }
        )
    }

    var body: some View {
        Section {
            LabeledContent("Folder") {
                Text(abbreviatedPath(account.account.configDir))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let organization = account.account.organization {
                LabeledContent("Organisation") {
                    Text(organization)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Picker("Token from", selection: source) {
                ForEach(CredentialSource.allCases, id: \.self) { source in
                    Text(source.label).tag(source)
                }
            }

            if source.wrappedValue == .selfContained {
                signInControls
                Text("Signs in with its own token, so macOS stops re-asking for Keychain access every time Claude Code rotates its token. If this sign-in ever stops working, the menu asks you to sign in again here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reads Claude Code's Keychain token. macOS re-asks for access whenever Claude Code rotates it — switch to self-contained sign-in to stop that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isExtraFolder {
                HStack {
                    Spacer()
                    Button("Remove folder", role: .destructive, action: onRemove)
                }
            }
        } header: {
            Text(account.account.displayName)
        }
        // Polling can drop a rejected sign-in on its own; re-read so this never shows
        // "Signed in" while the menu asks to sign in again.
        .onAppear { login.resync() }
        .onChange(of: login.isSignedIn) { _, _ in onIdentityChange() }
        .onChange(of: source.wrappedValue) { _, _ in onIdentityChange() }
        .onChange(of: account.authState) { _, state in
            if state == .signedOut {
                login.resync()
            }
        }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Shown before the user starts a sign-in, because the consent screen names Claude Code
    /// rather than ClaudeBar and that's alarming without warning.
    private var signInDisclosure: some View {
        Text("The browser will say **Claude Code** — Anthropic doesn't publish a third-party OAuth client for the usage endpoint, so ClaudeBar signs in as the CLI does. It asks for `\(OAuthConfig.scopes)` and nothing else, so it can't create API keys for your organisation. Both tokens live in ClaudeBar's own Keychain item: the access token is sent only to Anthropic's usage and account endpoints (the organisation lookup and the guest-pass and credit offers), the refresh token only to Anthropic's token and revoke endpoints.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var signInControls: some View {
        switch login.phase {
        // Both signed-out phases offer the same sign-in; the stale-scope one just explains
        // first why the user is looking at it again.
        case .signedOut, .signedOutStaleScope:
            Button("Sign in with Claude…") { login.startSignIn() }
            if login.phase == .signedOutStaleScope {
                Text("You were signed out because the earlier sign-in didn't match the access ClaudeBar now asks for. That token has been deleted and ClaudeBar asked Anthropic to revoke it. Sign in again to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            signInDisclosure

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
}
