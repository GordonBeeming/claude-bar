import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: UsageViewModel
    @Bindable var login: OAuthLoginController

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

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                    .help(model.launchAtLoginAvailable ? "" : "Available when installed as ClaudeBar.app")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
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
                    .disabled(pastedCode.trimmingCharacters(in: .whitespaces).isEmpty)
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
                        TextField("Paste code", text: $pastedCode)
                            .textFieldStyle(.roundedBorder)
                        Button("Submit") {
                            let code = pastedCode
                            pastedCode = ""
                            Task { await login.submitCode(code) }
                        }
                        .disabled(pastedCode.trimmingCharacters(in: .whitespaces).isEmpty)
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
