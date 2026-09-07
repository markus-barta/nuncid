import AppKit
import SwiftUI

enum OverlayMetrics {
    static let pinnedReservedChromeHeight: CGFloat = 104
    static let outerPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 8

    static func pinnedBodyHeight(totalHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - pinnedReservedChromeHeight)
    }

    static func temporaryBodyHeight(totalHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - outerPadding * 2 - 28)
    }

    static func preferredHeight(
        lines: [TicketLine],
        sticky: Bool,
        preferences: PresentationPreferences,
        width: CGFloat? = nil
    ) -> CGFloat {
        let resolvedWidth = max(360, width ?? (preferences.width == .custom ? preferences.customWidth : preferences.width.points))
        guard !lines.isEmpty else { return sticky ? 264 : 208 }
        let primary = stablePrimaryHeight(lines: lines, preferences: preferences, width: resolvedWidth)
        let alternatives = min(preferences.alternativePreviews, max(0, lines.count - 1))
        let rail = alternativeBlockHeight(count: alternatives, sticky: sticky, preferences: preferences)
        let body = primary + (rail > 0 ? sectionSpacing + rail : 0)
        return ceil(body + (sticky ? pinnedReservedChromeHeight : outerPadding * 2 + 28))
    }

    static func size(lines: [TicketLine], sticky: Bool, preferences: PresentationPreferences, visibleFrame: CGRect) -> CGSize {
        if preferences.width == .custom {
            return OverlaySizePolicy.clamped(
                CGSize(width: preferences.customWidth, height: preferences.customHeight),
                visibleFrame: visibleFrame
            )
        }
        let width = min(preferences.width.points, max(OverlaySizePolicy.minimum.width, visibleFrame.width - 24))
        let preferred = preferredHeight(lines: lines, sticky: sticky, preferences: preferences, width: width)
        return OverlaySizePolicy.clampedToVisibleMaximum(
            CGSize(width: width, height: preferred),
            visibleFrame: visibleFrame
        )
    }

    static func visibleAlternativeCount(
        lines: [TicketLine],
        preferences: PresentationPreferences,
        width: CGFloat,
        totalHeight: CGFloat,
        sticky: Bool
    ) -> Int {
        guard !lines.isEmpty else { return 0 }
        let requested = min(preferences.alternativePreviews, max(0, lines.count - 1))
        guard requested > 0 else { return 0 }
        let primary = stablePrimaryHeight(lines: lines, preferences: preferences, width: width)
        let available = sticky
            ? pinnedBodyHeight(totalHeight: totalHeight)
            : temporaryBodyHeight(totalHeight: totalHeight)
        return stride(from: requested, through: 1, by: -1).first { count in
            primary + sectionSpacing + alternativeBlockHeight(
                count: count,
                sticky: sticky,
                preferences: preferences
            ) <= available
        } ?? 0
    }

    static func primaryHeight(line: TicketLine, preferences: PresentationPreferences, width: CGFloat) -> CGFloat {
        let cardPadding = preferences.density.verticalPadding
        let textWidth = max(160, width - outerPadding * 2 - cardPadding * 2)
        let scale = preferences.textSize.scale
        let keyFont = NSFont.monospacedSystemFont(ofSize: 15 * scale, weight: .bold)
        let detailFont = NSFont.systemFont(ofSize: 13 * scale)
        let metadataFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let header = max(22, lineHeight(for: keyFont))
        let title = primaryTitleHeight(line: line, preferences: preferences, width: width)

        var childHeights = [header, title]
        if preferences.density.showsDetail, !line.detail.isEmpty {
            childHeights.append(boundedTextHeight(line.detail, font: detailFont, width: textWidth, lineLimit: preferences.density.detailLines))
        }
        if preferences.density.showsMetadata, !line.metadata.isEmpty {
            childHeights.append(boundedTextHeight(line.metadata, font: metadataFont, width: textWidth, lineLimit: 1))
        }
        let spacing = preferences.density == .compact ? CGFloat(6) : CGFloat(10)
        return ceil(childHeights.reduce(0, +) + CGFloat(max(0, childHeights.count - 1)) * spacing + cardPadding * 2)
    }

    static func stablePrimaryHeight(lines: [TicketLine], preferences: PresentationPreferences, width: CGFloat) -> CGFloat {
        let stableTitle = stablePrimaryTitleHeight(lines: lines, preferences: preferences, width: width)
        return lines.map {
            primaryHeight(line: $0, preferences: preferences, width: width)
                - primaryTitleHeight(line: $0, preferences: preferences, width: width)
                + stableTitle
        }.max() ?? 0
    }

    static func primaryTitleHeight(line: TicketLine, preferences: PresentationPreferences, width: CGFloat) -> CGFloat {
        let textWidth = max(160, width - outerPadding * 2 - preferences.density.verticalPadding * 2)
        let titleFont = NSFont.systemFont(ofSize: 17 * preferences.textSize.scale, weight: .semibold)
        let titleLines = preferences.density == .detailed ? 3 : 2
        return boundedTextHeight(line.title, font: titleFont, width: textWidth, lineLimit: titleLines)
    }

    static func stablePrimaryTitleHeight(lines: [TicketLine], preferences: PresentationPreferences, width: CGFloat) -> CGFloat {
        lines.map { primaryTitleHeight(line: $0, preferences: preferences, width: width) }.max() ?? 0
    }

    static func alternativeBlockHeight(count: Int, sticky: Bool, preferences: PresentationPreferences) -> CGFloat {
        guard count > 0 else { return 0 }
        let headerCount = min(2, count)
        let header = lineHeight(for: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)) * CGFloat(headerCount)
        let headerSpacing = CGFloat(headerCount) * 4
        let rows = CGFloat(count) * (43 * preferences.textSize.scale) + CGFloat(max(0, count - 1))
        let secondRailSpacing = CGFloat(max(0, headerCount - 1)) * sectionSpacing
        let hint = sticky ? 0 : sectionSpacing + lineHeight(for: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize))
        return ceil(header + headerSpacing + rows + secondRailSpacing + hint)
    }

    static func boundedTextHeight(_ text: String, font: NSFont, width: CGFloat, lineLimit: Int) -> CGFloat {
        guard !text.isEmpty, width > 0, lineLimit > 0 else { return 0 }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return min(ceil(bounds.height), lineHeight(for: font) * CGFloat(lineLimit))
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func previewScale(
        contentWidth: CGFloat,
        availableWidth: CGFloat,
        contentHeight: CGFloat,
        maximumHeight: CGFloat = 300
    ) -> CGFloat {
        guard contentWidth > 0, contentHeight > 0, availableWidth > 0, maximumHeight > 0 else { return 0 }
        return min(1, availableWidth / contentWidth, maximumHeight / contentHeight)
    }
}

enum OverlaySizePolicy {
    static let minimum = CGSize(width: 420, height: 260)
    static let fallbackMaximum = CGSize(width: 1_100, height: 900)

    static func clamped(_ size: CGSize, visibleFrame: CGRect?) -> CGSize {
        let maximum = visibleFrame.map {
            CGSize(width: max(minimum.width, $0.width - 16), height: max(minimum.height, $0.height - 16))
        } ?? fallbackMaximum
        return CGSize(
            width: min(max(size.width, minimum.width), maximum.width),
            height: min(max(size.height, minimum.height), maximum.height)
        )
    }

    static func clampedToVisibleMaximum(_ size: CGSize, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(size.width, max(1, visibleFrame.width - 16)),
            height: min(size.height, max(1, visibleFrame.height - 16))
        )
    }
}

enum NeighborRailPolicy {
    static func indices(count: Int, selectedIndex: Int, visibleCount: Int) -> (previous: [Int], next: [Int]) {
        guard count > 1, visibleCount > 0 else { return ([], []) }
        let selected = ((selectedIndex % count) + count) % count
        let limit = min(visibleCount, count - 1)
        var previous: [Int] = []
        var next: [Int] = []
        var used = Set([selected])
        for distance in 1..<count where previous.count + next.count < limit {
            let nextIndex = (selected + distance) % count
            if used.insert(nextIndex).inserted, previous.count + next.count < limit {
                next.append(nextIndex)
            }
            let previousIndex = (selected - distance + count) % count
            if used.insert(previousIndex).inserted, previous.count + next.count < limit {
                previous.insert(previousIndex, at: 0)
            }
        }
        return (previous, next)
    }
}

private final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct StatusPill: View {
    let state: String
    private var color: Color {
        switch state.lowercased() {
        case "done", "accepted", "merged", "closed", "success": return .green
        case "in-progress", "in_progress", "open": return .blue
        case "blocked", "cancelled", "failure", "timed-out", "action-required": return .red
        default: return .secondary
        }
    }
    var body: some View {
        Text((state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : state).replacingOccurrences(of: "_", with: " ").uppercased())
            .font(.caption2.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4).background(color.opacity(0.12), in: Capsule())
    }
}

enum TicketKeyMotionStyle: Equatable {
    case matchedFlight
    case opacityOnly
}

enum TicketKeyMotionPolicy {
    static let titleSettleDelay: TimeInterval = 0.38

    static func style(reduceMotion: Bool) -> TicketKeyMotionStyle {
        reduceMotion ? .opacityOnly : .matchedFlight
    }
}

enum TicketTitleSettlePolicy {
    static func nextGeneration(after current: Int) -> Int {
        current + 1
    }

    static func isSettled(
        navigationGeneration: Int,
        settledGeneration: Int,
        reduceMotion: Bool
    ) -> Bool {
        reduceMotion || settledGeneration >= navigationGeneration
    }

    static func completedGeneration(current: Int, callbackGeneration: Int) -> Int {
        max(current, callbackGeneration)
    }
}

enum SpatialRailBoundary: Equatable {
    case top
    case bottom

    var edge: Edge {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

enum SpatialRailTransitionPolicy {
    static let directionLeadTime: TimeInterval = 1.0 / 120.0

    static func boundaries(navigationDirection: Int) -> (insertion: SpatialRailBoundary, removal: SpatialRailBoundary) {
        navigationDirection >= 0
            ? (insertion: .bottom, removal: .top)
            : (insertion: .top, removal: .bottom)
    }
}

enum PinnedHeaderLayoutPolicy {
    static func contextWidth(totalWidth: CGFloat) -> CGFloat {
        min(176, max(72, totalWidth / 2 - 110))
    }
}

private enum TicketKeyRole: Equatable {
    case primary
    case neighbor
}

private struct TicketKeyLabel: View {
    let line: TicketLine
    let role: TicketKeyRole
    let preferences: PresentationPreferences
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder var body: some View {
        if TicketKeyMotionPolicy.style(reduceMotion: reduceMotion) == .matchedFlight {
            styledLabel
                .matchedGeometryEffect(
                    id: "ticket-key-\(line.id)",
                    in: namespace,
                    properties: .frame,
                    anchor: .center,
                    isSource: role == .primary
                )
                .zIndex(20)
        } else {
            styledLabel
                .contentTransition(.opacity)
        }
    }

    @ViewBuilder private var styledLabel: some View {
        switch role {
        case .primary:
            Text(line.key)
                .font(.system(size: 15 * preferences.textSize.scale, weight: .bold, design: .monospaced))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .fixedSize()
        case .neighbor:
            Text(line.key)
                .font(.system(size: 12.5 * preferences.textSize.scale, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(minWidth: 88, alignment: .leading)
        }
    }
}

private struct TicketTitleLabel: View {
    let line: TicketLine
    let role: TicketKeyRole
    let preferences: PresentationPreferences
    let namespace: Namespace.ID
    let primaryTitleSettled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder var body: some View {
        if TicketKeyMotionPolicy.style(reduceMotion: reduceMotion) == .matchedFlight {
            styledLabel
                .matchedGeometryEffect(
                    id: "ticket-title-\(line.id)",
                    in: namespace,
                    properties: .frame,
                    anchor: .leading,
                    isSource: role == .primary
                )
                .zIndex(19)
        } else {
            styledLabel
                .contentTransition(.opacity)
        }
    }

    @ViewBuilder private var styledLabel: some View {
        switch role {
        case .primary:
            Text(line.title)
                .font(.system(size: 17 * preferences.textSize.scale, weight: .semibold))
                .lineLimit(primaryTitleSettled ? (preferences.density == .detailed ? 3 : 2) : 1)
                .fixedSize(horizontal: false, vertical: true)
        case .neighbor:
            Text(line.title)
                .font(.system(size: 12.5 * preferences.textSize.scale, weight: .medium))
                .lineLimit(1)
        }
    }
}

struct PrimaryResultCard: View {
    let line: TicketLine
    let preferences: PresentationPreferences
    let keyNamespace: Namespace.ID
    let fixedHeight: CGFloat
    let titleSlotHeight: CGFloat
    let primaryTitleSettled: Bool
    let showsPin: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: preferences.density == .compact ? 6 : 10) {
            HStack(spacing: 8) {
                TicketKeyLabel(line: line, role: .primary, preferences: preferences, namespace: keyNamespace)
                StatusPill(state: line.state)
                Spacer(minLength: 8)
                SourceDestinationLink(line: line)
                if showsPin { PinToggleButton(isPinned: isPinned, action: onTogglePin) }
            }
            TicketTitleLabel(
                line: line,
                role: .primary,
                preferences: preferences,
                namespace: keyNamespace,
                primaryTitleSettled: primaryTitleSettled
            )
            .frame(height: titleSlotHeight, alignment: .topLeading)
            .clipped()
            if preferences.density.showsDetail, !line.detail.isEmpty {
                Text(line.detail).font(.system(size: 13 * preferences.textSize.scale)).foregroundStyle(.secondary).lineLimit(preferences.density.detailLines).fixedSize(horizontal: false, vertical: true)
            }
            if preferences.density.showsMetadata, !line.metadata.isEmpty { Text(line.metadata).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(preferences.density.verticalPadding).frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: fixedHeight, alignment: .top)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.82)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.accentColor).frame(width: 4).padding(.vertical, 10)
        }
    }
}

private struct SourceDestinationLink: View {
    let line: TicketLine
    @State private var hovering = false

    var body: some View {
        if let destination = line.destinationURL {
            Link(destination: destination) { linkedLabel }
                .buttonStyle(.plain)
                .help("Open \(line.source.uppercased()) record")
                .accessibilityLabel("Open \(line.key) in \(line.source.uppercased())")
                .onHover { hovering = $0 }
        } else {
            Text(line.source.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
    }

    private var linkedLabel: some View {
        HStack(spacing: 3) {
            Text(line.source.uppercased())
            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(hovering ? 0.12 : 0.001), in: Capsule())
        .contentShape(Capsule())
    }
}

private struct PinToggleButton: View {
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(isPinned ? -18 : 0))
                .offset(y: isPinned ? 1 : 0)
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(isPinned ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(isPinned ? 0.20 : 0.06)))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin card" : "Pin card")
        .accessibilityLabel(isPinned ? "Unpin card" : "Pin card")
    }
}

struct AlternativeResultRow: View {
    let position: Int
    let line: TicketLine
    let preferences: PresentationPreferences
    let keyNamespace: Namespace.ID
    var body: some View {
        HStack(spacing: 8) {
            Text("\(position)")
                .font(.caption2.monospacedDigit().weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).background(Color.primary.opacity(0.07), in: Circle())
            TicketKeyLabel(line: line, role: .neighbor, preferences: preferences, namespace: keyNamespace)
            TicketTitleLabel(
                line: line,
                role: .neighbor,
                preferences: preferences,
                namespace: keyNamespace,
                primaryTitleSettled: true
            )
            Spacer(minLength: 4)
            Text(line.source.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            StatusPill(state: line.state)
        }.padding(.horizontal, 8).frame(height: 43 * preferences.textSize.scale)
    }
}

struct OverlayContent: View {
    let lines: [TicketLine]
    let selectedIndex: Int
    let navigationGeneration: Int
    let navigationDirection: Int
    let sticky: Bool
    let shortcutLabel: String
    let statusText: String?
    let inputText: String?
    let projectPreview: String?
    let preferences: PresentationPreferences
    let constrainedSize: CGSize
    let scrollModifier: PopupScrollModifier
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onCycleResult: (Int) -> Void
    let onCycleProject: (Int) -> Void
    var zoomPercent: Int = 100
    var detectionEnabled: Bool = false
    var baselineSize: CGSize? = nil
    var onZoom: (Int) -> Void = { _ in }
    private var contentSize: CGSize { baselineSize ?? constrainedSize }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ticketKeyNamespace
    @State private var settledTitleGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectionHeader
                .frame(height: InspectionZoom.headerHeight)
                .padding(.horizontal, 10)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                    resultBody
                        .frame(height: OverlayMetrics.pinnedBodyHeight(totalHeight: contentSize.height), alignment: .top)
                    pinnedFooter.fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(width: contentSize.width, height: max(0, contentSize.height - InspectionZoom.headerHeight), alignment: .top)
                .scaleEffect(InspectionZoom(zoomPercent).scale, anchor: .topLeading)
                .frame(width: contentSize.width * InspectionZoom(zoomPercent).scale,
                       height: max(0, contentSize.height - InspectionZoom.headerHeight) * InspectionZoom(zoomPercent).scale,
                       alignment: .topLeading)
            }
        }
        .frame(width: constrainedSize.width, height: constrainedSize.height, alignment: .top)
        .background { surface }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18)))
        .onChange(of: navigationGeneration) { generation in
            if reduceMotion {
                settledTitleGeneration = TicketTitleSettlePolicy.completedGeneration(
                    current: settledTitleGeneration,
                    callbackGeneration: generation
                )
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + TicketKeyMotionPolicy.titleSettleDelay) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        settledTitleGeneration = TicketTitleSettlePolicy.completedGeneration(
                            current: settledTitleGeneration,
                            callbackGeneration: generation
                        )
                    }
                }
            }
        }
        .onChange(of: reduceMotion) { enabled in
            if enabled {
                settledTitleGeneration = TicketTitleSettlePolicy.completedGeneration(
                    current: settledTitleGeneration,
                    callbackGeneration: navigationGeneration
                )
            }
        }
    }

    private var selectedLine: TicketLine? { lines.indices.contains(selectedIndex) ? lines[selectedIndex] : lines.first }
    private var primarySlotHeight: CGFloat {
        OverlayMetrics.stablePrimaryHeight(lines: lines, preferences: preferences, width: contentSize.width)
    }
    private var primaryTitleSlotHeight: CGFloat {
        OverlayMetrics.stablePrimaryTitleHeight(lines: lines, preferences: preferences, width: contentSize.width)
    }
    private var neighborIndices: (previous: [Int], next: [Int]) {
        let visibleCount = OverlayMetrics.visibleAlternativeCount(
            lines: lines,
            preferences: preferences,
            width: contentSize.width,
            totalHeight: contentSize.height,
            sticky: true
        )
        return NeighborRailPolicy.indices(
            count: lines.count,
            selectedIndex: selectedIndex,
            visibleCount: visibleCount
        )
    }

    @ViewBuilder private var resultBody: some View {
        VStack(alignment: .leading, spacing: OverlayMetrics.sectionSpacing) {
            neighborResults(indices: neighborIndices.previous, title: "PREVIOUS")
            if let line = selectedLine {
                PrimaryResultCard(
                    line: line,
                    preferences: preferences,
                    keyNamespace: ticketKeyNamespace,
                    fixedHeight: primarySlotHeight,
                    titleSlotHeight: primaryTitleSlotHeight,
                    primaryTitleSettled: TicketTitleSettlePolicy.isSettled(
                        navigationGeneration: navigationGeneration,
                        settledGeneration: settledTitleGeneration,
                        reduceMotion: reduceMotion
                    ),
                    showsPin: false,
                    isPinned: sticky,
                    onTogglePin: onTogglePin
                )
            } else {
                VStack(spacing: 12) {
                    if statusText?.hasPrefix("Checking") == true || statusText?.hasPrefix("Reading") == true {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                    Text(statusText ?? "Ready for a ticket number").font(.headline)
                    Text("Type a number, paste a ticket key, or point at another ID.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 160)
            }
            neighborResults(indices: neighborIndices.next, title: "NEXT")
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.88),
            value: selectedIndex
        )
    }

    private var inspectionHeader: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                GhostNavigationButton(systemName: "xmark", label: "Close inspection and stop detection", action: onClose)
                Text(detectionEnabled ? "Detection on" : "Detection off")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                PinnedNavigationButtons(resultNavigationEnabled: true, onCycleResult: onCycleResult, onCycleProject: onCycleProject)
                PinToggleButton(isPinned: sticky, action: onTogglePin)
            }.frame(height: 24)
            HStack(spacing: 6) {
                pinnedContext
                Spacer(minLength: 0)
                Text("Zoom").font(.caption2).foregroundStyle(.secondary)
                GhostNavigationButton(systemName: "minus", label: "Zoom out", enabled: zoomPercent > 30) { onZoom(-1) }
                Button("\(zoomPercent)%") { onZoom(0) }
                    .buttonStyle(.plain).font(.caption.monospacedDigit())
                    .frame(width: 42, height: 24)
                    .help("Reset zoom to 100%")
                    .accessibilityLabel("Zoom \(zoomPercent) percent; reset to 100 percent")
                GhostNavigationButton(systemName: "plus", label: "Zoom in", enabled: zoomPercent < 300) { onZoom(1) }
            }.frame(height: 24)
        }.contentShape(Rectangle())
    }

    private var pinnedContextWidth: CGFloat {
        min(PinnedHeaderLayoutPolicy.contextWidth(totalWidth: constrainedSize.width), max(0, constrainedSize.width - 180))
    }

    @ViewBuilder private var pinnedContext: some View {
        if (inputText?.isEmpty == false) || projectPreview != nil {
            HStack(spacing: 5) {
                if let inputText, !inputText.isEmpty {
                    Text(inputText)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                if let projectPreview {
                    Text("→ \(projectPreview)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(width: pinnedContextWidth, alignment: .leading)
            .clipped()
        }
    }

    @ViewBuilder private func neighborResults(indices: [Int], title: String) -> some View {
        if !indices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                        AlternativeResultRow(
                            position: index + 1,
                            line: lines[index],
                            preferences: preferences,
                            keyNamespace: ticketKeyNamespace
                        )
                            .transition(neighborTransition)
                        if offset < indices.count - 1 { Divider().padding(.leading, 38) }
                    }
                }
            }
        }
    }

    private var neighborTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let boundaries = SpatialRailTransitionPolicy.boundaries(
            navigationDirection: navigationDirection
        )
        return .asymmetric(
            insertion: .move(edge: boundaries.insertion.edge).combined(with: .opacity),
            removal: .move(edge: boundaries.removal.edge).combined(with: .opacity)
        )
    }

    @ViewBuilder private var surface: some View {
        if preferences.surface == .system && !reduceTransparency {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var pinnedFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "computermouse")
            Text("scroll: result")
            Text("·")
            Text("⇧ scroll: project")
            Text("·")
            Text("\(scrollModifier.symbol) scroll anywhere")
            Text("·")
            Text("type: ticket/project")
            Spacer()
            Text("\(shortcutLabel): pin").lineLimit(1)
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
    }
}

private struct PinnedNavigationButtons: View {
    let resultNavigationEnabled: Bool
    let onCycleResult: (Int) -> Void
    let onCycleProject: (Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            GhostNavigationButton(systemName: "chevron.left", label: "Previous project") {
                onCycleProject(-1)
            }
            GhostNavigationButton(systemName: "chevron.right", label: "Next project") {
                onCycleProject(1)
            }
            Divider().frame(height: 13).padding(.horizontal, 3)
            GhostNavigationButton(
                systemName: "chevron.up",
                label: "Previous result",
                enabled: resultNavigationEnabled
            ) {
                onCycleResult(-1)
            }
            GhostNavigationButton(
                systemName: "chevron.down",
                label: "Next result",
                enabled: resultNavigationEnabled
            ) {
                onCycleResult(1)
            }
        }
        .fixedSize()
        .padding(2)
        .background(Color.primary.opacity(0.035), in: Capsule())
    }
}

private struct GhostNavigationButton: View {
    let systemName: String
    let label: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(enabled ? (hovering ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.32))
                .frame(width: 21, height: 19)
                .background(Color.accentColor.opacity(enabled && hovering ? 0.12 : 0.001), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

struct AppearanceCardPreview: View {
    let preferences: PresentationPreferences
    private let sampleLines = [
        TicketLine(key: "NUNCID-36", state: "in-progress", title: "Navigate results spatially from anywhere", source: "ppm", metadata: "ticket · high priority", detail: "The current ticket stays fixed while clear previous and next destinations move around it."),
        TicketLine(key: "NUNCID-35", state: "done", title: "Open the source and read every neighboring ID", source: "ppm"),
        TicketLine(key: "#184", state: "review", title: "Refine source-aware matching", source: "gh"),
        TicketLine(key: "NUNCID-34", state: "done", title: "Remember a custom card size", source: "ppm"),
        TicketLine(key: "NUNCID-33", state: "done", title: "Pin directly without racing the popup", source: "ppm"),
        TicketLine(key: "NUNCID-37", state: "done", title: "Use F19 and other function keys as shortcuts", source: "ppm")
    ]

    var body: some View {
        GeometryReader { proxy in
            let actualWidth = preferences.width == .custom ? preferences.customWidth : preferences.width.points
            let height = preferences.width == .custom ? preferences.customHeight : OverlayMetrics.preferredHeight(lines: sampleLines, sticky: true, preferences: preferences)
            let scale = OverlayMetrics.previewScale(
                contentWidth: actualWidth,
                availableWidth: max(1, proxy.size.width - 4),
                contentHeight: height
            )
            OverlayContent(lines: sampleLines, selectedIndex: 0, navigationGeneration: 0, navigationDirection: 1, sticky: true, shortcutLabel: "⌥⇧Space", statusText: nil, inputText: nil, projectPreview: nil, preferences: preferences, constrainedSize: CGSize(width: actualWidth, height: height), scrollModifier: .option, onClose: {}, onTogglePin: {}, onCycleResult: { _ in }, onCycleProject: { _ in })
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: actualWidth * scale, height: height * scale, alignment: .topLeading)
                .accessibilityLabel("Live ticket card preview")
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(height: min(300, OverlayMetrics.preferredHeight(lines: sampleLines, sticky: true, preferences: preferences)))
        .clipped()
    }
}

@MainActor private final class OverlayViewState: ObservableObject {
    @Published var lines: [TicketLine] = []
    @Published var selectedIndex = 0
    @Published var navigationGeneration = 0
    @Published var navigationDirection = 1
    @Published var sticky = false
    @Published var shortcutLabel = "⌥⇧Space"
    @Published var statusText: String?
    @Published var inputText: String?
    @Published var projectPreview: String?
    @Published var preferences = PresentationPreferences.load()
    @Published var scrollModifier = PopupInteractionPreferences.load().scrollModifier
    @Published var zoomPercent = InspectionZoom.load().percent
    @Published var detectionEnabled = false
    @Published var baselineSize = CGSize(width: 520, height: 300)
}

private struct OverlayRootView: View {
    @ObservedObject var state: OverlayViewState
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onCycleResult: (Int) -> Void
    let onCycleProject: (Int) -> Void
    let onZoom: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            OverlayContent(
                lines: state.lines,
                selectedIndex: state.selectedIndex,
                navigationGeneration: state.navigationGeneration,
                navigationDirection: state.navigationDirection,
                sticky: state.sticky,
                shortcutLabel: state.shortcutLabel,
                statusText: state.statusText,
                inputText: state.inputText,
                projectPreview: state.projectPreview,
                preferences: state.preferences,
                constrainedSize: proxy.size,
                scrollModifier: state.scrollModifier,
                onClose: onClose,
                onTogglePin: onTogglePin,
                onCycleResult: onCycleResult,
                onCycleProject: onCycleProject,
                zoomPercent: state.zoomPercent,
                detectionEnabled: state.detectionEnabled,
                baselineSize: state.baselineSize,
                onZoom: onZoom
            )
        }
    }
}

@MainActor final class OverlayController: NSObject, NSWindowDelegate {
    var onCycleProject: ((Int) -> Void)?
    var onExploreNavigation: ((Int, Bool) -> Bool)?
    var onClose: (() -> Void)?
    var onInput: ((PinnedInputEvent) -> Void)?
    var onSelectionChange: ((TicketLine) -> Void)?
    var onExternalContentMayMove: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onPinStateChange: ((Bool) -> Void)?
    var onPresentationPreferencesChange: ((PresentationPreferences) -> Void)?

    private let panel: FocusablePanel
    private let viewState = OverlayViewState()
    private var displayedLines: [TicketLine] = []
    private var selectedIndex = 0
    private var navigationGeneration = 0
    private var navigationDirection = 1
    private var queuedResultDirections: [Int] = []
    private var resultNavigationScheduled = false
    private var anchorMouse = CGPoint.zero
    private var shortcutLabel = "⌥⇧Space"
    private var statusText: String?
    private var inputText: String?
    private var projectPreview: String?
    private var eventMonitor: Any?
    private var globalScrollMonitor: Any?
    private var preferenceObserver: NSObjectProtocol?
    private var interactionPreferenceObserver: NSObjectProtocol?
    private var screenParameterObserver: NSObjectProtocol?
    private var lastScrollAt = Date.distantPast
    private var scrollOpacityUntil: Date?
    private var scrollOpacityRestore: DispatchWorkItem?
    private var requestedScrollOpacity: CGFloat = 1
    private var opacityAnimation: Task<Void, Never>?
    private var isPositioningProgrammatically = false
    private var zoom = InspectionZoom.load()
    private var presentationPreferences = PresentationPreferences.load()
    private var interactionPreferences = PopupInteractionPreferences.load()
    private(set) var isSticky = false

    var isVisible: Bool { panel.isVisible }
    var isActive: Bool { panel.isKeyWindow }
    var selectedLine: TicketLine? { displayedLines.indices.contains(selectedIndex) ? displayedLines[selectedIndex] : displayedLines.first }
    var containsPointer: Bool { panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) }

#if DEBUG
    var debugOpacity: CGFloat { panel.alphaValue }
    var debugScrollPresentation: [String: Any] {
        ["target": requestedScrollOpacity, "pointerInside": containsPointer,
         "until": scrollOpacityUntil?.timeIntervalSince1970 ?? 0,
         "now": Date().timeIntervalSince1970, "frame": NSStringFromRect(panel.frame),
         "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
         "zoom": zoom.percent, "baseline": NSStringFromSize(contentBaseline), "overflow": hasOverflow]
    }

    func captureProbe(to url: URL) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func advanceCaptureProbe() {
        cycleResult(1)
    }

    func retreatCaptureProbe() {
        cycleResult(-1)
    }
#endif

    init(allowsCapture: Bool = false) {
        panel = FocusablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
#if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--overlay-zoom-probe"),
           CommandLine.arguments.indices.contains(index + 1), let percent = Int(CommandLine.arguments[index + 1]) {
            zoom = InspectionZoom(percent) // Presentation-only; never persist capture-probe settings.
        }
        if CommandLine.arguments.contains("--overlay-stress-probe") {
            presentationPreferences.alternativePreviews = 6
        }
        if CommandLine.arguments.contains("--overlay-minimum-stress-probe") {
            presentationPreferences = PresentationPreferences(
                alternativePreviews: 6,
                textSize: .extraLarge,
                width: .custom,
                density: .detailed,
                surface: .solid,
                customWidth: OverlaySizePolicy.minimum.width,
                customHeight: OverlaySizePolicy.minimum.height
            )
        }
#endif
        panel.delegate = self
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = false; panel.hidesOnDeactivate = false
        panel.sharingType = allowsCapture ? .readOnly : .none
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = OverlaySizePolicy.minimum
        panel.contentMaxSize = OverlaySizePolicy.fallbackMaximum
        panel.contentView = NSHostingView(rootView: OverlayRootView(
            state: viewState,
            onClose: { [weak self] in self?.onClose?() },
            onTogglePin: { [weak self] in self?.onTogglePin?() },
            onCycleResult: { [weak self] direction in self?.cycleResult(direction) },
            onCycleProject: { [weak self] direction in self?.cycleProject(direction) },
            onZoom: { [weak self] steps in self?.changeZoom(steps) }
        ))
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleGlobalScroll(event)
        }
        preferenceObserver = NotificationCenter.default.addObserver(forName: .nuncidPresentationPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let loaded = PresentationPreferences.load()
                guard loaded != self.presentationPreferences else { return }
                self.presentationPreferences = loaded
                if self.panel.isVisible { self.renderInspection() }
            }
        }
        interactionPreferenceObserver = NotificationCenter.default.addObserver(forName: .nuncidPopupInteractionPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.interactionPreferences = PopupInteractionPreferences.load()
                self.syncViewState()
            }
        }
        screenParameterObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.renderInspection()
            }
        }
        syncViewState()
    }

    deinit {
        scrollOpacityRestore?.cancel()
        opacityAnimation?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let interactionPreferenceObserver { NotificationCenter.default.removeObserver(interactionPreferenceObserver) }
        if let screenParameterObserver { NotificationCenter.default.removeObserver(screenParameterObserver) }
    }

    func show(_ lines: [TicketLine], near mouse: CGPoint, shortcutLabel: String = "⌥⇧Space") {
        guard !lines.isEmpty else { hide(); return }
        if isSticky { replacePinnedResults(lines); return }
        cancelQueuedResultNavigation()
        displayedLines = Array(lines.prefix(HoverResultPolicy.maximumResults)); selectedIndex = 0
        anchorMouse = mouse; self.shortcutLabel = shortcutLabel; statusText = nil
        renderTemporary(); panel.orderFrontRegardless()
    }

    func setDetectionEnabled(_ enabled: Bool) {
        if viewState.detectionEnabled != enabled { viewState.detectionEnabled = enabled }
    }
    func setShortcutLabel(_ label: String) { shortcutLabel = label; syncViewState() }

    private func changeZoom(_ steps: Int) {
        zoom = steps == 0 ? InspectionZoom() : zoom.changed(by: steps)
        zoom.persist()
        renderInspection()
    }

    func prepareExplorationNavigation(_ direction: Int) {
        navigationDirection = direction < 0 ? -1 : 1
        viewState.navigationDirection = navigationDirection
    }

    func showExploration(_ lines: [TicketLine], selecting id: String? = nil, status: String?, near point: CGPoint) {
        cancelQueuedResultNavigation()
        let previousID = selectedLine?.id
        if !isVisible { anchorMouse = point }
        displayedLines = Array(lines.prefix(HoverResultPolicy.maximumResults))
        selectedIndex = id.flatMap { selected in displayedLines.firstIndex { $0.id == selected } } ?? 0
        statusText = status; inputText = nil; projectPreview = nil
        if previousID != selectedLine?.id { navigationGeneration = TicketTitleSettlePolicy.nextGeneration(after: navigationGeneration) }
        if isSticky { renderPinned(useSavedPosition: false) } else { renderTemporary() }
        panel.orderFrontRegardless()
        if previousID != selectedLine?.id, let selectedLine { onSelectionChange?(selectedLine) }
    }

    func openPinned(shortcutLabel: String, status: String = "Reading near pointer…") {
        cancelQueuedResultNavigation()
        isSticky = true; displayedLines = []; selectedIndex = 0; statusText = status
        anchorMouse = NSEvent.mouseLocation
        inputText = nil; projectPreview = nil; self.shortcutLabel = shortcutLabel
        renderPinned(useSavedPosition: true)
        onPinStateChange?(true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSticky else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    func pin(shortcutLabel: String) {
        guard panel.isVisible else { openPinned(shortcutLabel: shortcutLabel); return }
        isSticky = true; self.shortcutLabel = shortcutLabel
        renderPinned(useSavedPosition: false)
        onPinStateChange?(true)
        panel.makeKeyAndOrderFront(nil)
    }

    func unpin() {
        guard panel.isVisible, isSticky else { return }
        isSticky = false
        inputText = nil; projectPreview = nil
        syncViewState()
        onPinStateChange?(false)
        panel.orderFrontRegardless()
    }

    func restorePinnedIfNeeded(shortcutLabel: String) {
        guard interactionPreferences.restorePinned, !panel.isVisible else { return }
        cancelQueuedResultNavigation()
        isSticky = true; displayedLines = []; selectedIndex = 0
        statusText = "Ready for a ticket number"
        anchorMouse = NSEvent.mouseLocation
        self.shortcutLabel = shortcutLabel
        renderPinned(useSavedPosition: true)
        panel.orderFrontRegardless()
    }

    func focusPinned() { guard isSticky else { return }; panel.makeKeyAndOrderFront(nil) }

    func replacePinnedResults(_ lines: [TicketLine], selecting key: String? = nil, status: String? = nil) {
        guard isVisible else { return }
        cancelQueuedResultNavigation()
        displayedLines = Array(lines.prefix(HoverResultPolicy.maximumResults))
        if let key, let index = displayedLines.firstIndex(where: { $0.key == key }) { selectedIndex = index }
        else { selectedIndex = min(selectedIndex, max(0, displayedLines.count - 1)) }
        statusText = status; renderPinned(useSavedPosition: false)
    }

    func setInput(_ value: String?, projectPreview: String? = nil) {
        inputText = value; self.projectPreview = projectPreview
        if isVisible { syncViewState() }
    }

    func showPinnedStatus(_ status: String) {
        guard isVisible else { return }
        cancelQueuedResultNavigation()
        displayedLines = []; selectedIndex = 0; statusText = status; renderPinned(useSavedPosition: false)
    }

    func closePinned() {
        guard isSticky else { return }
        onPinStateChange?(false)
        hide()
    }
    func hide() {
        cancelQueuedResultNavigation()
        scrollOpacityRestore?.cancel(); scrollOpacityRestore = nil; scrollOpacityUntil = nil
        setScrollOpacity(1, animated: false)
        panel.orderOut(nil); isSticky = false; inputText = nil; projectPreview = nil
        syncViewState()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioningProgrammatically else { return }
        onExternalContentMayMove?()
        if isSticky { savePinnedOrigin() }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        InspectionZoom.bounded(frameSize, visible: sender.screen?.visibleFrame ?? CGRect(origin: .zero, size: OverlaySizePolicy.fallbackMaximum))
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard !isPositioningProgrammatically, panel.isVisible else { return }
        renderInspection()
        onExternalContentMayMove?()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isPositioningProgrammatically else { return }
        let baseline = zoom.baseline(afterResize: panel.frame.size)
        presentationPreferences.width = .custom
        presentationPreferences.customWidth = baseline.width
        presentationPreferences.customHeight = baseline.height
        presentationPreferences.persist()
        onPresentationPreferencesChange?(presentationPreferences)
        if isSticky { savePinnedOrigin() }
        syncViewState()
    }

    func updatePointerPresentation() {
        guard let until = scrollOpacityUntil else { return }
        let opacity = PopupScrollPresentationPolicy.opacity(pointerInside: containsPointer, recentlyScrolling: Date() < until, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        setScrollOpacity(opacity)
        if opacity == 1 { scrollOpacityUntil = nil; scrollOpacityRestore?.cancel(); scrollOpacityRestore = nil }
    }

    private func noteExternalScroll() {
        scrollOpacityUntil = Date().addingTimeInterval(PopupScrollPresentationPolicy.settlingDelay)
        scrollOpacityRestore?.cancel()
        let restore = DispatchWorkItem { [weak self] in
            self?.scrollOpacityUntil = nil
            self?.setScrollOpacity(1)
        }
        scrollOpacityRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + PopupScrollPresentationPolicy.settlingDelay, execute: restore)
        updatePointerPresentation()
    }

    private func setScrollOpacity(_ value: CGFloat, animated: Bool = true) {
        guard requestedScrollOpacity != value || !animated else { return }
        requestedScrollOpacity = value
        opacityAnimation?.cancel(); opacityAnimation = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { panel.alphaValue = value; return }
        let from = panel.alphaValue
        // Explicit, bounded interpolation also updates NSPanel's model value
        // when a global event arrives outside an AppKit animation transaction.
        opacityAnimation = Task { [weak self] in
            for frame in 1...8 {
                guard let self, !Task.isCancelled else { return }
                let fraction = CGFloat(frame) / 8
                let eased = 1 - (1 - fraction) * (1 - fraction)
                panel.alphaValue = from + (value - from) * eased
                if frame < 8 {
                    do { try await Task.sleep(nanoseconds: 15_000_000) } catch { return }
                }
            }
            self?.opacityAnimation = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }
        if event.type == .scrollWheel {
            let pointerInside = event.window === panel || panel.frame.contains(NSEvent.mouseLocation)
            if !pointerInside { noteExternalScroll() }
            let globalChord = event.modifierFlags.contains(interactionPreferences.scrollModifier.eventFlag)
            guard pointerInside || globalChord else { return event }
            let shiftingProject = pointerInside && event.modifierFlags.contains(.shift)
            let bodyContainsPointer = NSEvent.mouseLocation.y < panel.frame.maxY - InspectionZoom.headerHeight
            if pointerInside, bodyContainsPointer, hasOverflow, !globalChord, !shiftingProject, !event.modifierFlags.contains(.option) {
                return event // Native scroll view owns magnified overflow, not result cycling.
            }
            let delta = shiftingProject && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            navigateScroll(delta: delta, shiftingProject: shiftingProject, includeMisses: event.modifierFlags.contains(.option))
            return pointerInside ? nil : event
        }
        guard event.window === panel else { return event }
        guard panel.isKeyWindow else { return event }
        guard event.type == .keyDown else { return event }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
            onInput?(.paste(NSPasteboard.general.string(forType: .string) ?? "")); return nil
        }
        switch event.keyCode {
        case 36, 76: onInput?(.submit); return nil
        case 51, 117: onInput?(.backspace); return nil
        case 53: onInput?(.escape); return nil
        default: break
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers else { return event }
        let digits = characters.filter(\.isNumber)
        if !digits.isEmpty { onInput?(.digits(digits)); return nil }
        let letters = characters.filter(\.isLetter)
        if !letters.isEmpty { onInput?(.letters(letters)); return nil }
        return event
    }

    private func handleGlobalScroll(_ event: NSEvent) {
        guard panel.isVisible,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        noteExternalScroll()
        if event.modifierFlags.contains(interactionPreferences.scrollModifier.eventFlag) {
            navigateScroll(delta: event.scrollingDeltaY, shiftingProject: false, includeMisses: event.modifierFlags.contains(.option))
        }
        onExternalContentMayMove?()
    }

    private func navigateScroll(delta: CGFloat, shiftingProject: Bool, includeMisses: Bool) {
        guard abs(delta) > 0.1, Date().timeIntervalSince(lastScrollAt) > 0.10 else { return }
        lastScrollAt = Date()
        let direction = delta > 0 ? -1 : 1
        if shiftingProject { cycleProject(direction) }
        else if onExploreNavigation?(direction, includeMisses) != true { cycleResult(direction, explore: false) }
    }

    private func cycleResult(_ direction: Int, explore: Bool = true) {
        if explore, onExploreNavigation?(direction, false) == true { return }
        guard displayedLines.count > 1 else { return }
        queuedResultDirections.append(direction >= 0 ? 1 : -1)
        scheduleNextResultNavigation()
    }

    private func scheduleNextResultNavigation() {
        guard !resultNavigationScheduled, let direction = queuedResultDirections.first else { return }
        resultNavigationScheduled = true
        navigationDirection = direction
        viewState.navigationDirection = direction
        DispatchQueue.main.asyncAfter(deadline: .now() + SpatialRailTransitionPolicy.directionLeadTime) { [weak self] in
            self?.applyScheduledResultNavigation()
        }
    }

    private func applyScheduledResultNavigation() {
        guard resultNavigationScheduled, !queuedResultDirections.isEmpty else { return }
        let direction = queuedResultDirections.removeFirst()
        resultNavigationScheduled = false
        guard displayedLines.count > 1 else {
            queuedResultDirections.removeAll()
            return
        }
        navigationGeneration = TicketTitleSettlePolicy.nextGeneration(after: navigationGeneration)
        selectedIndex = CircularNavigation.advancedIndex(current: selectedIndex, direction: direction, count: displayedLines.count)
        inputText = nil; projectPreview = nil; syncViewState()
        if let selectedLine { onSelectionChange?(selectedLine) }
        scheduleNextResultNavigation()
    }

    private func cancelQueuedResultNavigation() {
        queuedResultDirections.removeAll()
        resultNavigationScheduled = false
    }

    private func cycleProject(_ direction: Int) {
        cancelQueuedResultNavigation()
        let normalizedDirection = direction >= 0 ? 1 : -1
        navigationDirection = normalizedDirection
        viewState.navigationDirection = normalizedDirection
        onCycleProject?(normalizedDirection)
    }

    private var requestedBaseline: CGSize {
        let savedWidth = presentationPreferences.width == .custom ? presentationPreferences.customWidth : presentationPreferences.width.points
        let width = savedWidth.isFinite ? min(10_000, max(100, savedWidth)) : CardWidth.standard.points
        let savedHeight = presentationPreferences.width == .custom ? presentationPreferences.customHeight : OverlayMetrics.preferredHeight(lines: displayedLines, sticky: true, preferences: presentationPreferences, width: width)
        let height = savedHeight.isFinite ? min(10_000, max(InspectionZoom.headerHeight + 1, savedHeight)) : 440
        return CGSize(width: width, height: height)
    }

    private var contentBaseline: CGSize {
        let requested = requestedBaseline
        let width = max(360, requested.width)
        return CGSize(width: width, height: max(requested.height,
            OverlayMetrics.preferredHeight(lines: displayedLines, sticky: true, preferences: presentationPreferences, width: width)))
    }

    private var hasOverflow: Bool {
        contentBaseline.width * zoom.scale > panel.frame.width + 1 ||
            (contentBaseline.height - InspectionZoom.headerHeight) * zoom.scale > panel.frame.height - InspectionZoom.headerHeight + 1
    }

    private func renderTemporary() { renderInspection() }
    private func renderPinned(useSavedPosition: Bool) { renderInspection(useSavedPosition: useSavedPosition) }

    private func renderInspection(useSavedPosition: Bool = false) {
        let shouldRemainFocused = panel.isKeyWindow
        guard let targetScreen = panel.isVisible ? (panel.screen ?? screen(containing: anchorMouse)) : screen(containing: anchorMouse) else { return }
        let visible = targetScreen.visibleFrame
        let size = InspectionZoom.bounded(zoom.requestedSize(baseline: requestedBaseline), visible: visible)
        var origin = panel.frame.origin
        if useSavedPosition { origin = savedOrigin(for: targetScreen, size: size) }
        else if !panel.isVisible {
            origin = CGPoint(x: anchorMouse.x + 18, y: anchorMouse.y - size.height - 18)
            if origin.x + size.width > visible.maxX { origin.x = anchorMouse.x - size.width - 18 }
            if origin.y < visible.minY { origin.y = anchorMouse.y + 18 }
        }
        origin = PanelPlacement.clamped(origin: origin, size: size, visibleFrame: visible)
        isPositioningProgrammatically = true
        updatePanelSizeLimits(for: targetScreen)
        syncViewState()
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        isPositioningProgrammatically = false
        if shouldRemainFocused { panel.makeKey() }
    }

    private func syncViewState() {
        viewState.lines = displayedLines
        viewState.selectedIndex = selectedIndex
        viewState.navigationGeneration = navigationGeneration
        viewState.navigationDirection = navigationDirection
        viewState.sticky = isSticky
        viewState.shortcutLabel = shortcutLabel
        viewState.statusText = statusText
        viewState.inputText = inputText
        viewState.projectPreview = projectPreview
        viewState.preferences = presentationPreferences
        viewState.scrollModifier = interactionPreferences.scrollModifier
        viewState.zoomPercent = zoom.percent
        viewState.baselineSize = contentBaseline
    }

    private func updatePanelSizeLimits(for screen: NSScreen) {
        panel.contentMinSize = InspectionZoom.bounded(InspectionZoom.minimumWindow, visible: screen.visibleFrame)
        panel.contentMaxSize = InspectionZoom.bounded(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), visible: screen.visibleFrame
        )
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func screenID(_ screen: NSScreen) -> String { String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
    private func savedOrigin(for screen: NSScreen, size: CGSize) -> CGPoint {
        let key = "pinnedOrigin.\(screenID(screen))"
        if let value = UserDefaults.standard.string(forKey: key) {
            let parts = value.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { return PanelPlacement.clamped(origin: CGPoint(x: parts[0], y: parts[1]), size: size, visibleFrame: screen.visibleFrame) }
        }
        return PanelPlacement.clamped(origin: CGPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.maxY - size.height - 20), size: size, visibleFrame: screen.visibleFrame)
    }
    private func savePinnedOrigin() {
        guard let screen = panel.screen else { return }
        UserDefaults.standard.set("\(panel.frame.origin.x),\(panel.frame.origin.y)", forKey: "pinnedOrigin.\(screenID(screen))")
    }
}
