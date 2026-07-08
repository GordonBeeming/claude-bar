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

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                    .help(model.launchAtLoginAvailable ? "" : "Available when installed as ClaudeBar.app")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
