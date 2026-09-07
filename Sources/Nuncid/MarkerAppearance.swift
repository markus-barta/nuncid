import AppKit
import SwiftUI

/// Queued and actively resolving candidates share one *visual* state. This
/// never changes resolver outcomes, cache ownership, or navigation eligibility.
enum MarkerVisualState: String, CaseIterable, Identifiable {
    case unchecked, missed, matched
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unchecked: return "Unchecked"
        case .missed: return "No match"
        case .matched: return "Matched"
        }
    }
    var explanation: String {
        switch self {
        case .unchecked: return "Not checked yet or still checking."
        case .missed: return "No Paimos or GitHub match was verified. Option + scroll can retry."
        case .matched: return "A Paimos or GitHub ticket was verified."
        }
    }
    var dash: [CGFloat] { self == .unchecked ? [3, 4] : [] }
}

enum MarkerColor {
    static func normalized(_ raw: String) -> String? {
        let value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + value.uppercased()
    }

    static func nsColor(_ raw: String) -> NSColor {
        let value = UInt32((normalized(raw) ?? "#808080").dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        let values = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", values[0], values[1], values[2])
    }
}

struct MarkerStyle: Codable, Equatable {
    var outlineColor: String
    var outlineOpacity: Double
    var fillColor: String
    var fillOpacity: Double
    var strikeThroughEnabled: Bool
    var strikeThroughColor: String
    var strikeThroughOpacity: Double

    static func defaults(for state: MarkerVisualState) -> Self {
        let color: String
        switch state {
        case .unchecked: color = "#808080"
        case .missed: color = "#555555"
        case .matched: color = "#34C759"
        }
        return Self(outlineColor: color, outlineOpacity: state == .unchecked ? 0.7 : 1,
                    fillColor: color, fillOpacity: state == .matched ? 0.1 : 0,
                    strikeThroughEnabled: state == .missed,
                    strikeThroughColor: color, strikeThroughOpacity: 0.5)
    }

    func normalized(for state: MarkerVisualState) -> Self {
        let fallback = Self.defaults(for: state)
        func opacity(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : fallback
        }
        return Self(
            outlineColor: MarkerColor.normalized(outlineColor) ?? fallback.outlineColor,
            outlineOpacity: opacity(outlineOpacity, fallback.outlineOpacity),
            fillColor: MarkerColor.normalized(fillColor) ?? fallback.fillColor,
            fillOpacity: opacity(fillOpacity, fallback.fillOpacity),
            strikeThroughEnabled: strikeThroughEnabled,
            strikeThroughColor: MarkerColor.normalized(strikeThroughColor) ?? fallback.strikeThroughColor,
            strikeThroughOpacity: opacity(strikeThroughOpacity, fallback.strikeThroughOpacity)
        )
    }
}

struct MarkerAppearancePreferences: Codable, Equatable {
    static let defaultsKey = "exploration.markerAppearance.v1"
    var unchecked = MarkerStyle.defaults(for: .unchecked)
    var missed = MarkerStyle.defaults(for: .missed)
    var matched = MarkerStyle.defaults(for: .matched)

    subscript(state: MarkerVisualState) -> MarkerStyle {
        get {
            switch state { case .unchecked: return unchecked; case .missed: return missed; case .matched: return matched }
        }
        set {
            switch state { case .unchecked: unchecked = newValue; case .missed: missed = newValue; case .matched: matched = newValue }
        }
    }

    var normalized: Self {
        Self(unchecked: unchecked.normalized(for: .unchecked),
             missed: missed.normalized(for: .missed), matched: matched.normalized(for: .matched))
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return decoded.normalized
    }

    func persist(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .nuncidMarkerAppearanceDidChange, object: nil)
    }
}

extension Notification.Name {
    static let nuncidMarkerAppearanceDidChange = Notification.Name("nuncid.markerAppearanceDidChange")
}

/// Shared by actual screen markers and the settings preview. Opacity belongs
/// to each layer, not the whole frame: selected emphasis changes width only.
@MainActor enum MarkerRenderer {
    static func draw(bounds: CGRect, state: MarkerVisualState, selected: Bool, style: MarkerStyle) {
        guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else { return }
        let style = style.normalized(for: state)
        let frame = bounds.insetBy(dx: -5, dy: -3)
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        if style.fillOpacity > 0 {
            MarkerColor.nsColor(style.fillColor).withAlphaComponent(style.fillOpacity).setFill()
            path.fill()
        }
        if style.outlineOpacity > 0 {
            path.lineWidth = selected ? 1.5 : 0.9
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.setLineDash(state.dash, count: state.dash.count, phase: 0)
            MarkerColor.nsColor(style.outlineColor).withAlphaComponent(style.outlineOpacity).setStroke()
            path.stroke()
        }
        if style.strikeThroughEnabled, style.strikeThroughOpacity > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let diagonal = NSBezierPath()
            diagonal.lineWidth = 0.75
            diagonal.lineCapStyle = .round
            diagonal.move(to: CGPoint(x: frame.minX + 1, y: frame.minY + 1))
            diagonal.line(to: CGPoint(x: frame.maxX - 1, y: frame.maxY - 1))
            MarkerColor.nsColor(style.strikeThroughColor).withAlphaComponent(style.strikeThroughOpacity).setStroke()
            diagonal.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

@MainActor private final class MarkerPreviewView: NSView {
    var state: MarkerVisualState = .unchecked
    var style = MarkerStyle.defaults(for: .unchecked)
    var selected = false
    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: "NUNCID-123", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 21, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
        let size = text.size()
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        text.draw(in: rect)
        MarkerRenderer.draw(bounds: rect, state: state, selected: selected, style: style)
    }
}

struct MarkerAppearancePreview: NSViewRepresentable {
    let state: MarkerVisualState
    let style: MarkerStyle
    var selected = false
    func makeNSView(context: Context) -> NSView { MarkerPreviewView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MarkerPreviewView else { return }
        view.state = state; view.style = style; view.selected = selected
        view.needsDisplay = true
    }
}

struct MarkerAppearanceEditor: View {
    @Binding var preferences: MarkerAppearancePreferences
    @State private var selection: MarkerVisualState = .unchecked

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Detection state", selection: $selection) {
                ForEach(MarkerVisualState.allCases) { state in Text(state.title).tag(state) }
            }.pickerStyle(.segmented)
            Text(selection.explanation).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                VStack {
                    MarkerAppearancePreview(state: selection, style: preferences[selection]).frame(height: 55)
                    Text("Normal").font(.caption).foregroundStyle(.secondary)
                }
                VStack {
                    MarkerAppearancePreview(state: selection, style: preferences[selection], selected: true).frame(height: 55)
                    Text("Selected").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            layerRow("Outline", color: \.outlineColor, opacity: \.outlineOpacity)
            layerRow("Fill", color: \.fillColor, opacity: \.fillOpacity)
            Divider()
            Toggle("Diagonal strike-through", isOn: Binding(
                get: { preferences[selection].strikeThroughEnabled },
                set: { preferences[selection].strikeThroughEnabled = $0 }
            ))
            layerRow("Strike-through", color: \.strikeThroughColor, opacity: \.strikeThroughOpacity)
                .disabled(!preferences[selection].strikeThroughEnabled)
            Text("Colors and opacity are independent for each layer. Selected IDs use a slightly thicker outline—not extra badges or glow.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset This State") { preferences[selection] = .defaults(for: selection) }
                Spacer()
                Button("Reset All Marker Styles") { preferences = MarkerAppearancePreferences() }
            }
        }
    }

    private func layerRow(_ title: String, color: WritableKeyPath<MarkerStyle, String>, opacity: WritableKeyPath<MarkerStyle, Double>) -> some View {
        HStack(spacing: 12) {
            ColorPicker(title + " color", selection: Binding(
                get: { Color(nsColor: MarkerColor.nsColor(preferences[selection][keyPath: color])) },
                set: { if let hex = MarkerColor.hex(NSColor($0)) { preferences[selection][keyPath: color] = hex } }
            ), supportsOpacity: false)
            .frame(width: 185, alignment: .leading)
            Slider(value: Binding(
                get: { preferences[selection][keyPath: opacity] },
                set: { preferences[selection][keyPath: opacity] = ($0 * 100).rounded() / 100 }
            ), in: 0...1)
            .accessibilityValue("\(Int((preferences[selection][keyPath: opacity] * 100).rounded())) percent")
            .accessibilityLabel("\(selection.title) \(title.lowercased()) opacity")
            Text("\(Int((preferences[selection][keyPath: opacity] * 100).rounded()))%")
                .font(.callout.monospacedDigit()).frame(width: 42, alignment: .trailing)
        }
    }
}
