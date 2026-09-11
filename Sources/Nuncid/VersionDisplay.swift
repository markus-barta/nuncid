import AppKit
import SwiftUI

/// One presentation source for SwiftUI and native menu titles. Only explicitly
/// tagged v2 coordinates receive weighting; the underlying string is intact.
@MainActor enum VersionDisplay {
    struct Design: Decodable {
        struct Tint: Decodable { let segments: [String]; let mix: Double }
        let scheme: String
        let design_revision: Int
        let segments: [String]
        let weights: [String: Double]
        let tint: Tint
    }

    static let design: Design = {
        guard let url = NuncidBrand.resourceURL(named: "calendar-version-display", extension: "json"),
              let data = try? Data(contentsOf: url),
              let design = try? JSONDecoder().decode(Design.self, from: data),
              design.scheme == VersionScheme.calendarV2.rawValue, design.design_revision == 3 else {
            preconditionFailure("Missing or invalid pinned calendar display data")
        }
        return design
    }()

    static func attributed(_ version: String, scheme: VersionScheme?, prefix: String = "",
                           font: NSFont, color: NSColor = .labelColor, appearance: NSAppearance? = nil) -> NSAttributedString {
        var inherited = color
        var accent = NSColor.controlAccentColor
        (appearance ?? NSApplication.shared.effectiveAppearance).performAsCurrentDrawingAppearance {
            inherited = color.usingColorSpace(.sRGB) ?? color
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        }
        let result = NSMutableAttributedString(string: prefix + version, attributes: [.font: font, .foregroundColor: inherited])
        guard scheme == .calendarV2, CalendarVersionV2(version) != nil else { return result }
        let offset = (prefix as NSString).length
        let ranges = ["yy": NSRange(location: offset, length: 2), "mm": NSRange(location: offset + 2, length: 2),
                      "dd": NSRange(location: offset + 4, length: 2), "hh": NSRange(location: offset + 6, length: 2),
                      "mi": NSRange(location: offset + 8, length: 2), "ss": NSRange(location: offset + 10, length: 2),
                      "tail": NSRange(location: offset + 12, length: 4)]
        if prefix.hasSuffix("v") {
            result.addAttribute(.foregroundColor, value: inherited.withAlphaComponent(inherited.alphaComponent * design.weights["v"]!), range: NSRange(location: offset - 1, length: 1))
        }
        for segment in design.segments where segment != "v" {
            guard let range = ranges[segment], let weight = design.weights[segment] else { continue }
            // Resolve the actual view appearance before bridging to SwiftUI;
            // its preferredColorScheme can differ from NSApp's appearance.
            let resolved = design.tint.segments.contains(segment) ? mix(inherited, accent, amount: design.tint.mix) : inherited
            let segmentColor = resolved.withAlphaComponent(resolved.alphaComponent * weight)
            result.addAttribute(.foregroundColor, value: segmentColor, range: range)
        }
        return result
    }

    /// Oklab color mixing, matching the doctrine's color-mix(in oklab, ...).
    nonisolated private static func mix(_ base: NSColor, _ accent: NSColor, amount: Double) -> NSColor {
        func lab(_ color: NSColor) -> (Double, Double, Double) {
            let c = color.usingColorSpace(.sRGB) ?? .black
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        let a = lab(base), b = lab(accent)
        let l = a.0 * (1 - amount) + b.0 * amount
        let x = a.1 * (1 - amount) + b.1 * amount
        let y = a.2 * (1 - amount) + b.2 * amount
        let ll = pow(l + 0.3963377774 * x + 0.2158037573 * y, 3)
        let mm = pow(l - 0.1055613458 * x - 0.0638541728 * y, 3)
        let ss = pow(l - 0.0894841775 * x - 1.2914855480 * y, 3)
        func encoded(_ v: Double) -> Double {
            min(1, max(0, v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055))
        }
        return NSColor(srgbRed: encoded(4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss),
                       green: encoded(-1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss),
                       blue: encoded(-0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss), alpha: base.alphaComponent)
    }
}

struct VersionText: View {
    @Environment(\.colorScheme) private var colorScheme
    let version: String
    let scheme: VersionScheme?
    var prefix = ""
    var size: CGFloat = 13
    var weight: NSFont.Weight = .regular
    var color: NSColor = .labelColor

    var body: some View {
        Text(AttributedString(VersionDisplay.attributed(version, scheme: scheme, prefix: prefix,
            font: .monospacedSystemFont(ofSize: size, weight: weight), color: color,
            appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua))))
            .lineLimit(1)
            .accessibilityLabel(prefix + version)
    }
}
