import ClaudeBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var model: UsageViewModel

    var body: some View {
        Form {
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
    private func celebrationRow(_ trigger: CelebrationTrigger) -> some View {
        let enabled = Binding(
            get: { settings.celebrationEnabled(for: trigger) },
            set: { settings.setCelebrationEnabled($0, for: trigger) }
        )
        let reaction = Binding(
            get: { settings.reaction(for: trigger) },
            set: { settings.setReaction($0, for: trigger) }
        )

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
