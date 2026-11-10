import AppKit
import ClaudeBarCore
import SwiftUI

struct UsageMenuView: View {
    @Bindable var model: UsageViewModel
    var settings: AppSettings

    @Environment(\.openSettings) private var openSettings

    private static let maxSectionsHeight: CGFloat = 460

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // The 1s tick only runs while this window is open, so live countdowns
            // cost nothing while the menu is closed.
            VStack(alignment: .leading, spacing: 8) {
                header(now: context.date)

                if let lastError = model.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.accounts.count == 1, let only = model.accounts.first {
                    // One account looks exactly as it always has: no account heading.
                    accountMessages(only)
                    Divider()
                    rows(for: only, now: context.date)
                } else {
                    // Many accounts would push the footer off screen, so the sections scroll
                    // once they pass a cap; header and footer stay put.
                    CappedScrollView(maxHeight: Self.maxSectionsHeight) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                                if index > 0 {
                                    Divider()
                                }
                                accountSection(account, now: context.date)
                            }
                        }
                    }
                }

                Divider()

                HStack {
                    Button("Settings…") {
                        // An accessory app's Settings window otherwise opens behind
                        // every other window, since the app itself never activates.
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }

                    Spacer()

                    Text(AppVersion.currentShort)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(AppVersion.currentDisplay)

                    Spacer()

                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut("q")
                }
            }
            .padding()
            .frame(width: 320)
        }
        // MenuBarExtra keeps the window height it first measured, so without this the
        // popover never shrinks when a Window disappears and leaves empty space below.
        // Applied outside the TimelineView so the window tracks whatever it renders.
        .fixedSize(horizontal: false, vertical: true)
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
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        if model.accounts.count == 1, let only = model.accounts.first {
            Text(updatedText(for: only, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func updatedText(for account: AccountUsageModel, now: Date) -> String {
        account.lastUpdated.map { ResetFormatting.updatedAgoString(since: $0, now: now) } ?? "Never updated"
    }

    /// With several accounts each one is headed by its email (or folder name), with the
    /// organisation and age of the data on a caption line.
    @ViewBuilder
    private func accountSection(_ account: AccountUsageModel, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.account.displayName)
                .font(.subheadline.weight(.semibold))
            let caption = [account.account.organization, updatedText(for: account, now: now)]
                .compactMap { $0 }
                .joined(separator: " · ")
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        accountMessages(account)
        rows(for: account, now: now)
    }

    @ViewBuilder
    private func accountMessages(_ account: AccountUsageModel) -> some View {
        if let bannerText = bannerText(for: account) {
            Text(bannerText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let lastError = account.lastError {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rows(for account: AccountUsageModel, now: Date) -> some View {
        if account.limits.isEmpty && account.lastError == nil {
            Text("Loading usage…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let sorted = LimitPresentation.sorted(account.limits)
            // `UsageLimit.id` can collide for scoped limits missing a model display
            // name, so identify rows by their stable offset instead.
            ForEach(Array(sorted.enumerated()), id: \.offset) { index, limit in
                if index > 0 {
                    Divider()
                }
                LimitRowView(
                    limit: limit,
                    now: now,
                    severity: settings.thresholds.resolve(for: limit),
                    displayMode: settings.usageDisplayMode
                )
            }
        }
    }

    private func bannerText(for account: AccountUsageModel) -> String? {
        switch account.authState {
        case .ok: return nil
        case .tokenExpired: return "Token expired — open Claude Code to refresh"
        case .noToken: return "Claude Code credentials not found"
        case .signedOut: return "Signed out — sign in again in Settings"
        }
    }
}

/// Scrolls its content once it is taller than `maxHeight`, and otherwise takes exactly the
/// content's height, so a short list sizes the popover the way a plain stack would.
private struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
