import AppKit

/// Status items inherit contrast from the menu bar, not the app's window
/// appearance. Even semantic label colors can be black on a dark menu bar
/// (for example, a light app over a dark wallpaper). Let AppKit render the
/// template, including highlighted, inactive-display and accessibility states.
@MainActor enum MenuBarIconPresentation {
    static func apply(to button: NSStatusBarButton, mode: HoverActivationMode,
                      hoverEnabled: Bool, matchFound: Bool) {
        switch HoverMenuBarState.resolve(mode: mode, hoverEnabled: hoverEnabled, matchFound: matchFound) {
        case .matchFound:
            button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel("Nuncid, hover on, ticket found")
        case .active:
            button.image = NSImage(systemSymbolName: "viewfinder.circle.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel("Nuncid, hover on")
        case .inactive:
            button.image = NuncidBrand.menuBarIcon
            let label = mode == .off
                ? "Nuncid, scanning off. Left-click to choose an ID; right-click for Settings."
                : (mode == .pressToScan
                    ? "Nuncid, press to scan. Left-click to choose an ID; right-click for Settings."
                    : "Nuncid, hover off. Left-click to choose an ID; right-click for Settings.")
            button.setAccessibilityLabel(label)
        }
        button.image?.isTemplate = true
        // Reset on every transition too: no stale accent/green/label tint.
        button.contentTintColor = nil
        button.toolTip = "Left-click to choose an ID (again to cancel) · Right-click for Settings"
        button.setAccessibilityHelp(
            "Left-click, then point at or click an ID to scan once. Click Nuncid again to cancel; right-click for Settings."
        )
    }
}
