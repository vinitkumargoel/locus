import SwiftUI

// MARK: - Shared reusable atoms used across screens.

/// Animated audio-level meter (port of the prototype's `meterBars`).
struct MeterBars: View {
    @Environment(\.theme) private var theme
    let count: Int
    let active: Bool
    var seed: Double = 0
    var maxHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let h: CGFloat = active
                        ? 4 + CGFloat(abs(sin(t * 5 + Double(i) * 1.3 + seed))) * (maxHeight - 4)
                        : 3
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active ? theme.rec : theme.text3)
                        .frame(width: 3, height: h)
                        .opacity(active ? 1 : 0.5)
                }
            }
            .frame(height: maxHeight, alignment: .bottom)
        }
    }
}

/// macOS-style sliding pill toggle. Visual only — taps call `action`.
struct PillToggle: View {
    @Environment(\.theme) private var theme
    let isOn: Bool
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        let w: CGFloat = large ? 42 : 32
        let h: CGFloat = large ? 25 : 19
        let knob: CGFloat = large ? 20 : 15
        let inset: CGFloat = large ? 2.5 : 2
        Capsule()
            .fill(isOn ? theme.accent : theme.border)
            .frame(width: w, height: h)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .offset(x: isOn ? w - knob - inset : inset)
            }
            .animation(.easeInOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}

/// A status dot that can pulse (port of `recPulse`).
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    var size: CGFloat = 9
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing && animating ? 0.28 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: animating
            )
            .onAppear { if pulsing { animating = true } }
            .onChange(of: pulsing) { _, newValue in animating = newValue }
    }
}

// MARK: - View modifiers

private struct HoverHighlight: ViewModifier {
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hovering ? theme.hover : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Wash the row background on hover (port of `style-hover="background:var(--hover)"`).
    func hoverHighlight(cornerRadius: CGFloat = 7) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    /// Floating card surface: card fill + hairline border + drop shadow.
    func floatingSurface(_ theme: Theme, cornerRadius: CGFloat = 12) -> some View {
        self
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(theme.border, lineWidth: 0.5)
            )
            .shadow(color: theme.shadowColor, radius: theme.shadowRadius, y: theme.shadowY)
    }

    /// Thin hairline border around a surface.
    func hairline(_ color: Color, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color, lineWidth: 1)
        )
    }
}
