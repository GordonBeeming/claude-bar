import SwiftUI

/// A 0–100% bar showing the three severity zones, with draggable handles on the
/// warning and critical boundaries. Dragging a handle past its neighbour is
/// blocked one percent short, so the zones can shrink but never invert.
struct ThresholdBarView: View {
    @Binding var warningPercent: Double
    @Binding var criticalPercent: Double

    private let barHeight: CGFloat = 14
    private let handleSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let warningX = width * warningPercent / 100
                let criticalX = width * criticalPercent / 100

                ZStack(alignment: .leading) {
                    // Zone track: normal → warning → critical
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(.blue)
                            .frame(width: warningX)
                        Rectangle()
                            .fill(.orange)
                            .frame(width: max(criticalX - warningX, 0))
                        Rectangle()
                            .fill(.red)
                    }
                    .frame(height: barHeight)
                    .clipShape(Capsule())

                    handle(at: warningX, color: .orange)
                        .gesture(dragGesture(width: width) { percent in
                            warningPercent = min(percent, criticalPercent - 1)
                        })
                        .accessibilityLabel("Warning threshold")
                        .accessibilityValue("\(Int(warningPercent)) percent")

                    handle(at: criticalX, color: .red)
                        .gesture(dragGesture(width: width) { percent in
                            criticalPercent = max(percent, warningPercent + 1)
                        })
                        .accessibilityLabel("Critical threshold")
                        .accessibilityValue("\(Int(criticalPercent)) percent")
                }
                // Handles are offset within the ZStack, so a gesture attached to a
                // handle needs a coordinate space anchored to the static track —
                // otherwise `.local` resolves relative to the moving handle itself
                // and dragging jumps to the far left.
                .coordinateSpace(name: "bar")
            }
            .frame(height: handleSize)

            HStack {
                Text("Warning \(Int(warningPercent))%")
                    .foregroundStyle(.orange)
                Spacer()
                Text("Critical \(Int(criticalPercent))%")
                    .foregroundStyle(.red)
            }
            .font(.caption)
        }
    }

    private func handle(at x: CGFloat, color: Color) -> some View {
        Circle()
            .fill(.background)
            .overlay(Circle().strokeBorder(color, lineWidth: 3))
            .frame(width: handleSize, height: handleSize)
            .shadow(radius: 1, y: 0.5)
            // Center the handle on its boundary position.
            .offset(x: x - handleSize / 2)
    }

    private func dragGesture(width: CGFloat, apply: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("bar"))
            .onChanged { value in
                let percent = (value.location.x / width * 100).rounded()
                apply(min(max(percent, 1), 100))
            }
    }
}
