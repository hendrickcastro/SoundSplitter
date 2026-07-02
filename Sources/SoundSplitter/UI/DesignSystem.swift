import SwiftUI
import AppKit

/// Design tokens, inspired by FineTune's design system: a dark "glass" popover
/// over an NSVisualEffectView, flat rows that highlight on hover, an
/// accent-driven selection language, and hierarchical SF Symbols.
enum DS {
    // Radii
    static let popupRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 6

    // Spacing
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    // Surfaces
    static let hoverSurface = Color.primary.opacity(0.08)
    static let selectedSurface = Color.accentColor.opacity(0.10)
    static let trackColor = Color.primary.opacity(0.15)
    static let mutedColor = Color(nsColor: .systemRed).opacity(0.85)

    // Fonts
    static let sectionHeader = Font.system(size: 11, weight: .bold)
    static let rowTitle = Font.system(size: 13)
    static let rowSubtitle = Font.system(size: 10)
    static let percentage = Font.system(size: 11, weight: .medium).monospacedDigit()
}

/// Bridges an `NSVisualEffectView` so the popover gets the native blurred
/// material background (the "glass" look).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// Popover glass background: material + a subtle appearance-aware overlay.
    func glassBackground() -> some View {
        background(
            ZStack {
                VisualEffectBackground(material: .popover)
                Color(nsColor: .windowBackgroundColor).opacity(0.25)
            }
        )
    }

    /// Flat-at-rest row that reveals a surface fill on hover or when selected.
    func hoverRow(isSelected: Bool = false) -> some View {
        modifier(HoverRowModifier(isSelected: isSelected))
    }
}

private struct HoverRowModifier: ViewModifier {
    let isSelected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.rowRadius)
                    .fill(fill)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if isSelected { return DS.selectedSurface }
        return hovering ? DS.hoverSurface : .clear
    }
}

/// A mute button using a hierarchical, level-aware speaker glyph.
struct MuteButton: View {
    let muted: Bool
    let volume: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13))
                .foregroundStyle(muted ? DS.mutedColor : Color.primary)
                .frame(width: 18)
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if muted || volume <= 0.001 { return "speaker.slash.fill" }
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
