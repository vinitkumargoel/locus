import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var app = AppState(services: .live())

    var body: some Scene {
        // Main window — sidebar + screen router. Borderless, full-bleed; the
        // system draws the traffic-light controls over the sidebar top inset.
        Window("Locus", id: "main") {
            MainWindowView()
                .environmentObject(app)
                .environment(\.theme, app.dark ? .dark : .light)
                .preferredColorScheme(app.dark ? .dark : .light)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)

        // Menu-bar agent — the privacy-critical recording status item + popover.
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(app)
                .environment(\.theme, app.dark ? .dark : .light)
                .preferredColorScheme(app.dark ? .dark : .light)
        } label: {
            MenuBarLabel()
                .environmentObject(app)
        }
        .menuBarExtraStyle(.window)
    }
}
