import AppKit
import ClaudeBarCore
import SwiftUI

/// Draws the menu bar icon (Claude logomark + optional "NN%") into a bitmap, since
/// `MenuBarExtra`'s label renders whatever `NSImage` it's given without any further
/// SwiftUI-level tinting control.
@MainActor
enum MenuBarIconRenderer {
    private static let height: CGFloat = 18

    /// The exact Claude logomark (from claude.ai's favicon), recoloured to black and embedded
    /// as a monochrome template PNG so it tints with the menu bar and adapts to light/dark —
    /// the same approach CodexBar uses for the OpenAI knot. It's a 32×32 image shown at 16pt,
    /// which keeps the fine spokes crisp on Retina.
    private static let claudeMarkTemplateBase64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAQAAADZc7J/AAADPElEQVRIx33Va4iUVRgH8N87M3vVdNmgoFQqlsCCItGEwjJRgohAMKE+WBlIRSRaiVH0KSvSCIxE/NINsvrQFQq7+im7uBYtRplC4noBb7uuuzvu7szThzk7OzOr+7y8zJxz3vM//+f/XA61loGbdSBXNzfxO6XlsEXoNTeNMsy03dIayCm3Xy+UhfdQSO82oVdrgsvLXQqqctpJIQyZXeXwl3BAM7JJjtVMFOQU9NuBYW3WII/pZuCQEXk5ZY/ab62QnyzeOOlDQjhuGrhan7AVrXhSCOHGWk1ymOMFixPECqEorAU3GBVWg5VCyaiyrkaAXUJ4Kc18J4SjZuAOIdyGBSJB70juJcvjM2FI+EYnbhVGhOfxoHDKdO2Opu3djXmRwyx70/Ixd+JtIZxJXu9JrIrCgDn150/EYnMSKDztcn1CeMIG4RXPCCNKwn1oSiHN6t1gmcPCmLDTdiF0e1f4WTE5tQVt8vUJXsHKNKHVtsRiSEm44FQaj1a9r9hM81xRL0amGdztSNWZylNSFsJ8rZZY5x17HBP6dEGHK7U2VNurRlNVVLaWhTN2O10H3K0jM9ufOpx03hkDThl01mE9VnhM1MBO/D/noB6/+cUfxuBNx51QbKAdSg3jwz70lAVaauOXpTA2a9ekxTQFLcpGPWJdHQNO2+s/I9qU9OtzxAfKtRU5Ye02OSeMJQVCGPapow2cvnfZuP6ZTEEBLZ5zVgif6K/GoCTsxDUett3vhhLE7ROnFsADDgjhb8t8LewzWI1C+LH69bVWetlNjfWwK+FuxWvCr1YLXxkQTtgn7DcrpXJdJ8nh/kS4x11YJYQua4V7vCGEjd4XenWhRV5hXL0M7crCmE2aMN+osAEfC4u1GxTOm22z0O+WyfXIGq+bl7L8X+FzZHqEhXhcCLuxvireRXtzAV8IvToxR1HJdTVdaj0WOSt0aLhs8gqa8aIQFoGlwkmdSfdhYchcXGWjNpNuqzyWCGE52vCs8I+mpPtDqdlc0vJY7oJVaJLHR8JPxm8k3jLsXlLKXcQyle5faVY5B4Vv0+YK3VYNxOuVDJminLKQU/YlfqhZyxRlwpRW2+0KFl5itWr/AyEueJyW+cN7AAAAAElFTkSuQmCC"

    /// Deep, near-red flame for the more serious weekly over-pace signal.
    static let strongFlameColor = NSColor(srgbRed: 0.75, green: 0.12, blue: 0.12, alpha: 1)
    /// Lighter flame for the 5-hour session and model-scoped windows.
    static let lightFlameColor = NSColor.systemOrange

    /// `flameColor` nil means no pace flame at all (on pace, or the menu-bar flame
    /// switched off in settings). When non-nil it also picks the flame's colour, so
    /// weekly over-pace can read hotter than a session/scoped one.
    static func image(percent: Int?, severity: Severity, flameColor: NSColor?) -> NSImage {
        let symbolImage: NSImage? = claudeMark()

        // No percent means no pace signal either — there's nothing to be "ahead" of.
        let flameSymbol = (percent != nil ? flameColor : nil).map { flameImage(color: $0) } ?? nil

        // The menu bar flattens *template* images to a single system colour, so
        // showing warning/critical colour (or the pace flame) requires opting out
        // of template mode entirely; only plain `.normal`-and-on-pace stays
        // template so it still adapts to light/dark mode.
        let isTemplate = severity == .normal && flameSymbol == nil
        let tint = tintColor(for: severity)
        let renderedSymbol = symbolImage.map { isTemplate ? $0 : tinted($0, color: tint) }

        let text = percent.map { " \($0)%" }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textColor: NSColor = isTemplate ? .labelColor : tint
        let attributedText = text.map {
            NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: textColor])
        }

        let symbolSize = renderedSymbol?.size ?? NSSize(width: 16, height: 16)
        let textSize = attributedText?.size() ?? .zero
        let flameSize = flameSymbol?.size ?? .zero
        let spacing: CGFloat = attributedText != nil ? 2 : 0
        let flameSpacing: CGFloat = flameSymbol != nil ? 2 : 0
        let width = symbolSize.width + spacing + textSize.width + flameSpacing + flameSize.width

        // The block-based initializer lets AppKit call the drawing handler once per
        // required scale factor; `lockFocus`/`unlockFocus` only ever produces a
        // single 1x bitmap rep, which reads blurry on Retina menu bars.
        let composed = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            renderedSymbol?.draw(
                at: NSPoint(x: 0, y: (height - symbolSize.height) / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            attributedText?.draw(at: NSPoint(x: symbolSize.width + spacing, y: (height - textSize.height) / 2))
            flameSymbol?.draw(
                at: NSPoint(
                    x: symbolSize.width + spacing + textSize.width + flameSpacing,
                    y: (height - flameSize.height) / 2
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }

        composed.isTemplate = isTemplate
        return composed
    }

    /// Decodes the embedded Claude logomark as a template image sized to 16pt. Falls back to
    /// the `asterisk` symbol only if the embedded data ever fails to decode.
    private static func claudeMark() -> NSImage {
        let fallback = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude usage")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let image = Data(base64Encoded: claudeMarkTemplateBase64)
            .flatMap(NSImage.init(data:)) ?? fallback
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    /// The flame's colour comes from the over-pace *window*, not the severity — it's a
    /// burn-rate hint, so it doesn't follow the warning/critical tint.
    private static func flameImage(color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let base = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Ahead of pace")?
            .withSymbolConfiguration(config) else {
            return nil
        }
        return tinted(base, color: color)
    }

    private static func tintColor(for severity: Severity) -> NSColor {
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Standard NSImage recolouring trick: paint the fill colour, then clip it to
    /// the source image's existing alpha via `.sourceAtop`.
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            color.set()
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// The `MenuBarExtra` label. Scenes have no `.task`, so polling starts from this
/// view's `.onAppear` instead — guarded to a single loop inside the view model since
/// the label can appear more than once.
struct MenuBarLabelView: View {
    let model: UsageViewModel
    let settings: AppSettings
    let celebrations: CelebrationController

    var body: some View {
        let highest = model.highest
        Image(nsImage: MenuBarIconRenderer.image(
            percent: highest.map { Int($0.percent.rounded()) },
            severity: highest.map { settings.thresholds.resolve(for: $0) } ?? .normal,
            flameColor: flameColor
        ))
        .onAppear {
            model.attachCelebrations(settings: settings, controller: celebrations)
            model.startPolling()
        }
    }

    /// The flame is a burn-rate warning, not a property of the leading limit: fire it
    /// when *any* limit is over pace, even one that isn't the highest percent shown in
    /// the icon (e.g. a weekly burning hot while the session bar leads). Weekly
    /// (all-models) reads hotter — deep near-red — than the session/scoped windows,
    /// which stay the lighter orange. Re-evaluated on every 60s poll re-render, which
    /// is plenty for a signal this slow-moving.
    private var flameColor: NSColor? {
        guard settings.showMenuBarFlame else { return nil }
        let now = Date()
        let overPace = model.limits.filter { UsageWindow.isOverPace(for: $0, now: now) }
        guard !overPace.isEmpty else { return nil }
        let weeklyAllOverPace = overPace.contains { $0.kind == "weekly_all" }
        return weeklyAllOverPace ? MenuBarIconRenderer.strongFlameColor : MenuBarIconRenderer.lightFlameColor
    }
}
