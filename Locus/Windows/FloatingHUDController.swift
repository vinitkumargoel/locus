import SwiftUI
import AppKit

// MARK: - Floating recording bar (HUD)
//
// The app is pure SwiftUI (LocusApp declares only the main Window + MenuBarExtra
// scenes). To show a small recording bar that floats ABOVE other apps — including
// a full-screen Zoom/Slack call — and never steals keyboard focus, we drop down
// to AppKit and host a SwiftUI view inside a borderless, non-activating NSPanel.
//
// Lifecycle is driven entirely by AppState: `show()`/`hide()` are called from
// `syncHUDPresentation()` on `rec` / `hudEnabled` / `hudPreview` changes, and the
// expand/collapse + position come from AppState's `hudExpanded` / `hudPosX/Y`.
// The controller keeps a weak reference back to AppState (AppState owns the
// controller) so there's no retain cycle.

@MainActor
final class FloatingHUDController {
    private weak var app: AppState?
    private var panel: NSPanel?

    /// Card sizes INCLUDING the shadow padding the SwiftUI view draws around its
    /// `floatingSurface` (see `HUD.pad` in FloatingHUDView).
    private let collapsedSize = NSSize(width: 256, height: 78)
    private let expandedSize  = NSSize(width: 400, height: 470)
    /// Keep-on-screen inset from the visible frame edges.
    private let margin: CGFloat = 16

    // Drag state — captured in screen coordinates so panel movement can't feed
    // back into the delta (NSEvent.mouseLocation is absolute, unlike a SwiftUI
    // .global translation measured inside a window that is itself moving).
    private var dragMouseStart: NSPoint?
    private var dragOriginStart: NSPoint?

    /// Observes display reconfiguration (resolution change / monitor unplug) so the
    /// visible bar can re-clamp onto the new frame instead of being stranded.
    private var screenObserver: NSObjectProtocol?

    init(app: AppState) {
        self.app = app
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: Show / hide

    func show() {
        // Never materialize a real window inside an Xcode SwiftUI preview.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        guard let app else { return }

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: collapsedSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar                       // above normal windows
            // Ride along onto every Space, including other apps' full-screen
            // spaces, and stay out of the Cmd-` window cycle.
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false                        // SwiftUI draws its own
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isMovableByWindowBackground = false      // we do custom drag
            p.isReleasedWhenClosed = false

            let host = NSHostingView(rootView: HUDHost(controller: self).environmentObject(app))
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: collapsedSize)
            p.contentView = host
            panel = p

            if screenObserver == nil {
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.reclampToScreen() }
                }
            }
        }

        // Order the panel on screen FIRST so `panel.screen` is populated before we
        // compute its target frame (a never-shown NSWindow reports `screen == nil`,
        // which would otherwise fall back to the wrong display).
        panel?.orderFrontRegardless()
        let size = app.hudExpanded ? expandedSizeClamped() : collapsedSize
        panel?.setFrame(targetFrame(size: size), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Expand / collapse

    /// Resize the panel to the collapsed pill or the expanded transcript panel,
    /// keeping the top-left corner anchored so it grows down/right in place.
    func applyExpanded(_ expanded: Bool) {
        guard let panel, panel.isVisible else { return }
        let old = panel.frame
        let newSize = expanded ? expandedSizeClamped() : collapsedSize
        // Anchor the top-left corner so the panel grows down/right in place.
        let newOrigin = NSPoint(x: old.minX, y: old.maxY - newSize.height)
        var f = NSRect(origin: newOrigin, size: newSize)
        if let vf = currentVisibleFrame { f = clampFrame(f, in: vf) }
        panel.setFrame(f, display: true, animate: true)
        // Deliberately do NOT persist here: expand/collapse is a UI state change,
        // not a reposition. Position is normalized against the collapsed size (see
        // targetFrame/persistPosition) so it survives the size change unchanged;
        // only an actual drag or a preset jump writes a new saved position.
    }

    /// The expanded card capped to the current visible frame so its header and
    /// controls can never be pushed off-screen on a short/low-res display.
    private func expandedSizeClamped() -> NSSize {
        guard let vf = currentVisibleFrame else { return expandedSize }
        return NSSize(width: min(expandedSize.width, vf.width - 2 * margin),
                      height: min(expandedSize.height, vf.height - 2 * margin))
    }

    /// Re-fit the panel onto the current visible frame after a display change.
    private func reclampToScreen() {
        guard let panel, panel.isVisible, let vf = currentVisibleFrame else { return }
        panel.setFrame(clampFrame(panel.frame, in: vf), display: true)
    }

    // MARK: Position

    /// Re-place the panel from AppState's persisted normalized position (used by
    /// the Settings quick-jump grid and on show).
    func restorePosition() {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(targetFrame(size: panel.frame.size), display: true, animate: true)
    }

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragMouseStart == nil {
            dragMouseStart = mouse
            dragOriginStart = panel.frame.origin
        }
        guard let m0 = dragMouseStart, let o0 = dragOriginStart else { return }
        var newOrigin = NSPoint(x: o0.x + (mouse.x - m0.x), y: o0.y + (mouse.y - m0.y))
        if let vf = currentVisibleFrame {
            newOrigin = clampFrame(NSRect(origin: newOrigin, size: panel.frame.size), in: vf).origin
        }
        panel.setFrameOrigin(newOrigin)
    }

    func dragEnded() {
        dragMouseStart = nil
        dragOriginStart = nil
        persistPosition()
    }

    // MARK: Geometry

    private var currentVisibleFrame: NSRect? {
        if let s = panel?.screen { return s.visibleFrame }
        // Panel not yet on a screen: prefer the display under the pointer, then the
        // focus screen, then the menu-bar screen — never an arbitrary default.
        if let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return s.visibleFrame
        }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }

    /// Map AppState's normalized (0…1) top-left position into a clamped on-screen
    /// frame for `size`. 0 = left/top edge, 1 = right/bottom edge of the area the
    /// panel can occupy without clipping. Mirrored by `persistPosition()`.
    private func targetFrame(size: NSSize) -> NSRect {
        guard let vf = currentVisibleFrame else { return NSRect(origin: .zero, size: size) }
        let nx = clamp01(app?.hudPosX ?? 1.0)
        let ny = clamp01(app?.hudPosY ?? 0.0)
        // Normalize against a FIXED reference size (the collapsed pill) so the saved
        // top-left maps to the same screen point whether the bar is currently
        // collapsed or expanded — otherwise the position drifts across expand/collapse.
        let placeW = max(0, vf.width  - collapsedSize.width  - 2 * margin)
        let placeH = max(0, vf.height - collapsedSize.height - 2 * margin)
        let originX = vf.minX + margin + CGFloat(nx) * placeW
        let topY    = margin + CGFloat(ny) * placeH          // distance from vf top to panel top edge
        let originY = vf.maxY - topY - size.height
        return clampFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), in: vf)
    }

    /// Inverse of `targetFrame`: read the panel's actual frame back into AppState's
    /// normalized position (persisted via AppState's `didSet`).
    private func persistPosition() {
        guard let panel, let vf = currentVisibleFrame else { return }
        let size = panel.frame.size
        // Same FIXED reference basis as targetFrame so the round-trip is exact and
        // size-independent (collapse/expand can't shift the saved position).
        let placeW = max(1, vf.width  - collapsedSize.width  - 2 * margin)
        let placeH = max(1, vf.height - collapsedSize.height - 2 * margin)
        let nx = (panel.frame.minX - vf.minX - margin) / placeW
        let topY = vf.maxY - (panel.frame.minY + size.height)   // panel top edge → distance from vf top
        let ny = (topY - margin) / placeH
        app?.hudPosX = clamp01(Double(nx))
        app?.hudPosY = clamp01(Double(ny))
    }

    private func clampFrame(_ frame: NSRect, in vf: NSRect) -> NSRect {
        var f = frame
        let maxX = vf.maxX - f.width - margin
        let maxY = vf.maxY - f.height - margin
        f.origin.x = (maxX >= vf.minX + margin) ? min(max(f.origin.x, vf.minX + margin), maxX) : vf.minX + margin
        f.origin.y = (maxY >= vf.minY + margin) ? min(max(f.origin.y, vf.minY + margin), maxY) : vf.minY + margin
        return f
    }

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - Hosted root
//
// A thin wrapper so the theme/appearance environment stays reactive to dark-mode
// toggles: re-renders whenever AppState republishes, re-injecting `\.theme`.

private struct HUDHost: View {
    @EnvironmentObject private var app: AppState
    let controller: FloatingHUDController

    var body: some View {
        FloatingHUDView(controller: controller)
            .environment(\.theme, app.dark ? .dark : .light)
            .preferredColorScheme(app.dark ? .dark : .light)
    }
}
