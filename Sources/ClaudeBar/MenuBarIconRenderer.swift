import AppKit
import ClaudeBarCore
import SwiftUI

/// Draws the menu bar icon (asterisk glyph + optional "NN%") into a bitmap, since
/// `MenuBarExtra`'s label renders whatever `NSImage` it's given without any further
/// SwiftUI-level tinting control.
@MainActor
enum MenuBarIconRenderer {
    private static let height: CGFloat = 18

    static func image(percent: Int?, severity: Severity) -> NSImage {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let baseSymbol = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude usage")
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Claude usage")
        let symbolImage = baseSymbol?.withSymbolConfiguration(symbolConfig)

        // The menu bar flattens *template* images to a single system colour, so
        // showing warning/critical colour requires opting out of template mode
        // entirely; `.normal` stays template so it still adapts to light/dark mode.
        let isTemplate = severity == .normal
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
        let spacing: CGFloat = attributedText != nil ? 2 : 0
        let width = symbolSize.width + spacing + textSize.width

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
            return true
        }

        composed.isTemplate = isTemplate
        return composed
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

    var body: some View {
        let highest = model.highest
        Image(nsImage: MenuBarIconRenderer.image(
            percent: highest.map { Int($0.percent.rounded()) },
            severity: highest?.severity ?? .normal
        ))
        .onAppear {
            model.startPolling()
        }
    }
}
