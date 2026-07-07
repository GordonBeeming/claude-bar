import AppKit
import ClaudeBarCore
import SwiftUI

struct UsageMenuView: View {
    @Bindable var model: UsageViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // The 1s tick only runs while this window is open, so live countdowns
            // cost nothing while the menu is closed.
            VStack(alignment: .leading, spacing: 8) {
                header(now: context.date)

                if let bannerText {
                    Text(bannerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let lastError = model.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                rows(now: context.date)

                Divider()

                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                    .help(model.launchAtLoginAvailable ? "" : "Available when installed as ClaudeBar.app")

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding()
            .frame(width: 320)
        }
        .onAppear {
            model.refreshIfStale()
        }
    }

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack {
            Text("Claude")
                .font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        Text(model.lastUpdated.map { ResetFormatting.updatedAgoString(since: $0, now: now) } ?? "Never updated")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func rows(now: Date) -> some View {
        if model.limits.isEmpty && model.lastError == nil {
            Text("Loading usage…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let sorted = LimitPresentation.sorted(model.limits)
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, limit in
                if index > 0 {
                    Divider()
                }
                LimitRowView(limit: limit, now: now)
            }
        }
    }

    private var bannerText: String? {
        switch model.authState {
        case .ok: return nil
        case .tokenExpired: return "Token expired — open Claude Code to refresh"
        case .noToken: return "Claude Code credentials not found"
        }
    }
}
