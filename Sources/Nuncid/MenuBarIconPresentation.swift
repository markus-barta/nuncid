import AppKit

/// Status items inherit contrast from the menu bar, not the app's window
/// appearance. Even semantic label colors can be black on a dark menu bar
/// (for example, a light app over a dark wallpaper). Let AppKit render the
/// template, including highlighted, inactive-display and accessibility states.
@MainActor enum MenuBarIconPresentation {
    static func apply(to button: NSStatusBarButton, mode: HoverActivationMode,
                      hoverEnabled: Bool, matchFound: Bool, updateReady: Bool = false) {
        let state = HoverMenuBarState.resolve(mode: mode, hoverEnabled: hoverEnabled, matchFound: matchFound)
        button.image = image(for: state, updateReady: updateReady)
        switch state {
        case .matchFound:
            button.setAccessibilityLabel("Nuncid, detection on, ticket found")
        case .active:
            button.setAccessibilityLabel("Nuncid, detection on")
        case .inactive:
            button.setAccessibilityLabel("Nuncid, detection off. Left-click to turn on; right-click for Settings.")
        }
        if updateReady {
            let label = (button.accessibilityLabel() ?? "Nuncid").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            button.setAccessibilityLabel(label + ", update ready. Restart to Update in the menu.")
        }
        button.image?.isTemplate = true
        // Reset on every transition too: no stale accent/green/label tint.
        button.contentTintColor = nil
        button.toolTip = updateReady
            ? "Update ready · Right-click → Restart to Update"
            : "Left-click to toggle detection · Right-click for Settings"
        button.setAccessibilityHelp(
            "Left-click to toggle detection on or off. ON keeps the inspection window visible; OFF preserves a pinned window. Close stops detection and closes the window. Right-click for Settings."
        )
    }

    static func image(for state: HoverMenuBarState, updateReady: Bool) -> NSImage {
        let base: NSImage
        switch state {
        case .inactive: base = NuncidBrand.menuBarIcon
        case .active: base = NSImage(systemSymbolName: "viewfinder.circle.fill", accessibilityDescription: nil)!
        case .matchFound: base = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!
        }
        let result = updateReady ? withUpdateArrow(base) : base
        result.isTemplate = true
        return result
    }

    /// A transparent clearance around the arrow lets AppKit tint the whole
    /// image as one template on light, dark and highlighted menu bars.
    static func withUpdateArrow(_ base: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            base.draw(in: CGRect(x: (18 - base.size.width) / 2, y: (18 - base.size.height) / 2,
                                 width: base.size.width, height: base.size.height))
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 11.5, y: 9, width: 8.5, height: 10))
            context.restoreGState()
            NSColor.black.setStroke()
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            arrow.move(to: CGPoint(x: 16, y: 10.75))
            arrow.line(to: CGPoint(x: 16, y: 16.25))
            arrow.move(to: CGPoint(x: 13.75, y: 14))
            arrow.line(to: CGPoint(x: 16, y: 16.25))
            arrow.line(to: CGPoint(x: 18.25, y: 14))
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

#if DEBUG
    /// Offscreen rendering: no status item, window, capture permission or live
    /// updater is created. CI retains this light/dark, normal/ready comparison.
    static func capturePreview(to url: URL) throws {
        let preview = NSImage(size: CGSize(width: 480, height: 240), flipped: false) { _ in
            for dark in [false, true] {
                let y: CGFloat = dark ? 0 : 120
                let ink: NSColor = dark ? .white : .black
                (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
                NSBezierPath(rect: CGRect(x: 0, y: y, width: 480, height: 120)).fill()
                for (index, state) in [HoverMenuBarState.inactive, .active, .matchFound].enumerated() {
                    let x = CGFloat(index) * 160
                    let label = ["Detection off", "Detection on", "Ticket found"][index]
                    (label as NSString).draw(at: CGPoint(x: x + 14, y: y + 96), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink])
                    for ready in [false, true] {
                        let icon = image(for: state, updateReady: ready)
                        let tinted = NSImage(size: CGSize(width: 20, height: 18), flipped: false) { _ in
                            icon.draw(in: CGRect(x: ready ? 0 : (18 - icon.size.width) / 2,
                                                y: (18 - icon.size.height) / 2,
                                                width: icon.size.width, height: icon.size.height))
                            ink.setFill()
                            CGRect(x: 0, y: 0, width: 20, height: 18).fill(using: .sourceAtop)
                            return true
                        }
                        let left = x + (ready ? 92 : 26)
                        tinted.draw(in: CGRect(x: left, y: y + 64, width: 20, height: 18))
                        tinted.draw(in: CGRect(x: left - 10, y: y + 13, width: 40, height: 36))
                    }
                }
            }
            return true
        }
        guard let tiff = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
#endif
}
