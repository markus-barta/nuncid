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
            button.setAccessibilityLabel("Nuncid, detection on, ticket found")
        case .active:
            button.image = NSImage(systemSymbolName: "viewfinder.circle.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel("Nuncid, detection on")
        case .inactive:
            button.image = NuncidBrand.menuBarIcon
            button.setAccessibilityLabel("Nuncid, detection off. Left-click to turn on; right-click for Settings.")
        }
        button.image?.isTemplate = true
        // Reset on every transition too: no stale accent/green/label tint.
        button.contentTintColor = nil
        button.toolTip = "Left-click to toggle detection · Right-click for Settings"
        button.setAccessibilityHelp(
            "Left-click to toggle detection on or off. ON keeps the inspection window visible; OFF preserves a pinned window. Close stops detection and closes the window. Right-click for Settings."
        )
    }
}
