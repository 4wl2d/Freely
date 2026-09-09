import SwiftUI

/// Dots describe the presentation toggle, not third-party screen-capture behavior.
struct PanelBorder: View {
    let hiddenInPresentation: Bool
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(hiddenInPresentation ? Color.white.opacity(0.30) : ShellTheme.border,
                          style: hiddenInPresentation
                            ? StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0, 5])
                            : StrokeStyle(lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PanelDivider: View {
    let hiddenInPresentation: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(hiddenInPresentation ? .white.opacity(0.24) : ShellTheme.border),
                           style: hiddenInPresentation
                            ? StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0, 4])
                            : StrokeStyle(lineWidth: 1))
        }
        .frame(height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
