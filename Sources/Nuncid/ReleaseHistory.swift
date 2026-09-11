import AppKit
import SwiftUI

struct ReleaseNoteItem: Equatable {
    let label: String
    let detail: String
}

struct ReleaseNote: Identifiable, Equatable {
    let version: String
    let isoDate: String
    let date: String
    let theme: String
    let headline: String
    let intro: String
    let items: [ReleaseNoteItem]
    var versionScheme: VersionScheme = .legacy

    var id: String { version }
}

enum ReleaseHistory {
    static let notes: [ReleaseNote] = [
        ReleaseNote(
            version: "260911101807.0.0",
            isoDate: "2026-09-11",
            date: "11 September 2026",
            theme: "A clear version everywhere",
            headline: "See the date. Read the detail.",
            intro: "New releases use one precise UTC calendar coordinate, with a consistent visual rhythm wherever Nuncid shows its version.",
            items: [
                ReleaseNoteItem(label: "Your system colors", detail: "The date follows your macOS accent color. Time and suffix use quieter system text, with the same segment weights in Settings, About, Version History and the menu."),
                ReleaseNoteItem(label: "One identity, intact", detail: "Calendar v2 keeps the full version unchanged in release files and update checks. Earlier releases keep their original names and formatting.")
            ],
            versionScheme: .calendarV2
        ),
        ReleaseNote(
            version: "26.09.11.10.11.21",
            isoDate: "2026-09-11",
            date: "11 September 2026",
            theme: "Steady detection in live terminals",
            headline: "Keep your matches in view.",
            intro: "Changing terminal and text-UI window titles no longer repeatedly restart detection. Your detected references stay available while the terminal keeps working.",
            items: [
                ReleaseNoteItem(label: "Quiet by default", detail: "Automatic source-window refresh starts off for both new and existing setups, so a changing window title leaves your current scan in place."),
                ReleaseNoteItem(label: "Refresh on your terms", detail: "Enable Refresh when source window changes in Detection settings when you want automatic rescans. Scrolling still refreshes marker positions; toggle detection off and on for a fresh scan.")
            ],
            versionScheme: .calendar
        ),
        ReleaseNote(
            version: "26.09.07.17.32.24",
            isoDate: "2026-09-07",
            date: "7 September 2026",
            theme: "Inspection that stays with you",
            headline: "Turn it on. Keep it in view.",
            intro: "Detection now stays on until you turn it off. One consistent inspection window keeps your controls in place, with magnification that fits your display.",
            items: [
                ReleaseNoteItem(label: "A true toggle", detail: "The menu icon and activation shortcut turn detection on or off. ON keeps the window visible; OFF preserves a pinned window. Escape clears input first, while Close always closes."),
                ReleaseNoteItem(label: "One familiar header", detail: "Pinning no longer changes the layout. The permanent top-right pin is quiet gray when unpinned and tilted and pressed in when pinned. Typing and browsing do not stop discovery."),
                ReleaseNoteItem(label: "Your view, at your scale", detail: "Remember 30–300% zoom in 10-point steps, or click the percentage to reset to 100%. Content magnifies together; the header stays usable and oversized content scrolls within the display’s usable area.")
            ],
            versionScheme: .calendar
        ),
        ReleaseNote(
            version: "26.09.07.13.25.21",
            isoDate: "2026-09-07",
            date: "7 September 2026",
            theme: "The right reference, in context",
            headline: "Numbers need meaning, not guesses.",
            intro: "Nuncid now classifies local text before looking anything up. Times, percentages, counts, model names and paths no longer turn into unrelated ticket searches.",
            items: [
                ReleaseNoteItem(label: "Context before lookup", detail: "Explicit keys, PR labels, supported URLs and gh commands determine the reference type. Nearby context stays inside its text block and window; missing scope remains unresolved."),
                ReleaseNoteItem(label: "Workflow runs, too", detail: "Repository-scoped GitHub Actions runs get their own preview with workflow, status, branch, commit, duration and link. No logs or artifacts are fetched."),
                ReleaseNoteItem(label: "Room above the text", detail: "Detection frames gain 3 points of top headroom without moving their bottom edge. Only no-match results can use a diagonal; unchecked and verified matches never have a strike-through.")
            ],
            versionScheme: .calendar
        ),
        ReleaseNote(
            version: "26.09.07.07.09.01",
            isoDate: "2026-09-07",
            date: "7 September 2026",
            theme: "Quieter source markers",
            headline: "Three colors. Less visual noise.",
            intro: "Detection frames now communicate with simple color styles instead of check or question badges. Tune each layer without changing how Nuncid finds tickets.",
            items: [
                ReleaseNoteItem(label: "Clear at a glance", detail: "Unchecked and checking IDs share gray dashes at 70% opacity. No-match IDs use a dark-gray frame and a 50% diagonal; verified matches use green with a 10% fill."),
                ReleaseNoteItem(label: "Your own palette", detail: "Detection Frames settings provide independent outline, fill, and strike-through colors and opacity for all three states. Enable or disable the diagonal separately."),
                ReleaseNoteItem(label: "Preview without waiting", detail: "See normal and selected frames before your next lookup. Changes apply to visible markers immediately, without rescanning or repeating a tracker request.")
            ],
            versionScheme: .calendar
        ),
        ReleaseNote(
            version: "26.09.06.19.36.59",
            isoDate: "2026-09-06",
            date: "6 September 2026",
            theme: "Explore at your own pace",
            headline: "One invocation. A screen full of context.",
            intro: "Nuncid discovers IDs progressively around your pointer, resolves nearby candidates in parallel, and keeps their source markers and cards connected.",
            items: [
                ReleaseNoteItem(label: "Ready when you point", detail: "Hover briefly to prioritize an ID and open its cached card. Soft outlines distinguish queued and checking IDs; tiny check and question badges distinguish verified matches from unsuccessful lookups."),
                ReleaseNoteItem(label: "Browse, or deliberately retry", detail: "Scroll through matches and pending IDs. Option + scroll also includes unsuccessful IDs for another try. Outside scrolling gently fades the card and refreshes source markers without discarding context."),
                ReleaseNoteItem(label: "Simpler controls", detail: "One on-demand exploration action replaces the three activation modes. Tune hover delay and parallel lookups; close the card or press Escape to finish."),
                ReleaseNoteItem(label: "A date you can trust", detail: "Releases now use UTC calendar coordinates with explicit update metadata. Existing releases keep their identities, and macOS receives a lossless compatible bundle version.")
            ],
            versionScheme: .calendar
        ),
        ReleaseNote(
            version: "26.09.06.17.55.27",
            isoDate: "2026-09-06",
            date: "6 September 2026",
            theme: "Unpublished validation candidate",
            headline: "Retired before public delivery.",
            intro: "The first calendar reservation did not pass every packaged validation gate. It was not published or installed as a release.",
            items: [
                ReleaseNoteItem(label: "History stays truthful", detail: "This coordinate remains retired rather than being reused for different bytes."),
                ReleaseNoteItem(label: "A fresh, verified successor", detail: "The next candidate corrects canonical-version validation while retaining the exploration improvements.")
            ],
            versionScheme: .calendar
        ),
        ReleaseNote(
            version: "1.2.3",
            isoDate: "2026-09-06",
            date: "6 September 2026",
            theme: "Choose what to inspect",
            headline: "Click Nuncid, then point at the ID you mean.",
            intro: "The menu-bar icon now arms a single scan instead of reading nearby menu-bar numbers. Move to your target and let Nuncid inspect that spot.",
            items: [
                ReleaseNoteItem(label: "Point first, scan once", detail: "After clicking Nuncid, pause over an ID or click it. The menu bar itself never becomes the target."),
                ReleaseNoteItem(label: "Easy to cancel", detail: "Click Nuncid again or open its right-click menu to cancel. An unused selection expires after 15 seconds."),
                ReleaseNoteItem(label: "Shortcuts stay immediate", detail: "Press to Scan still scans at your current pointer when you use its shortcut. Your hover preferences and native menu-bar appearance stay unchanged.")
            ]
        ),
        ReleaseNote(
            version: "1.2.2",
            isoDate: "2026-09-06",
            date: "6 September 2026",
            theme: "At home in your menu bar",
            headline: "A clear icon, in light or dark.",
            intro: "Nuncid now lets macOS choose the menu-bar icon color, just like native status items, instead of borrowing a text color from the app.",
            items: [
                ReleaseNoteItem(label: "Native contrast", detail: "The icon stays readable against light and dark menu bars and follows the system when the appearance changes."),
                ReleaseNoteItem(label: "Familiar state shapes", detail: "Hover scanning and found tickets keep their distinct symbols, with native monochrome rendering and menu highlighting."),
                ReleaseNoteItem(label: "Your controls, unchanged", detail: "Left-click still scans once; right-click still opens Settings and controls. Shortcuts and preferences stay as you set them.")
            ]
        ),
        ReleaseNote(
            version: "1.2.1",
            isoDate: "2026-09-06",
            date: "6 September 2026",
            theme: "Ready for the next release",
            headline: "Keep finding updates as Nuncid grows.",
            intro: "This compatibility release prepares Nuncid to recognize future date-based releases while keeping the familiar version format today.",
            items: [
                ReleaseNoteItem(label: "A safe stepping stone", detail: "Install 1.2.1 before moving to calendar versions. Older builds can discover this update using their existing version checker."),
                ReleaseNoteItem(label: "Explicit update information", detail: "Future date-based updates must carry valid release metadata; missing or inconsistent information never becomes an update suggestion."),
                ReleaseNoteItem(label: "History stays intact", detail: "Existing releases keep their original versions, and the update checker never suggests an older release as an upgrade.")
            ]
        ),
        ReleaseNote(
            version: "1.2.0",
            isoDate: "2026-08-31",
            date: "31 August 2026",
            theme: "One click, one look",
            headline: "Scan once from the menu bar, exactly when you mean to.",
            intro: "Nuncid now gives each menu-bar click one clear job: left-click looks once near the pointer, while right-click keeps Settings and every familiar control close by.",
            items: [
                ReleaseNoteItem(label: "Look once, instantly", detail: "Left-click the menu-bar icon for one immediate scan without changing your saved shortcut or hover behavior."),
                ReleaseNoteItem(label: "A quiet confirmation", detail: "A polished, capture-excluded cue confirms the scan and gently reminds you where Settings live, with a calm Reduce Motion path."),
                ReleaseNoteItem(label: "Version truth at a glance", detail: "Right-click starts with the installed Nuncid version and an honest, bounded update status before the controls you already know.")
            ]
        ),
        ReleaseNote(
            version: "1.1.0",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "Context stays put",
            headline: "See exactly which ID Nuncid is using.",
            intro: "A polished lock-on now connects the card back to the text on screen, then keeps the active lookup obvious without interrupting your work.",
            items: [
                ReleaseNoteItem(label: "Found with a little magic", detail: "A luminous sweep resolves around the recognized ID once, then settles into a calm marker that follows you as you browse results."),
                ReleaseNoteItem(label: "Every match when you want it", detail: "A new pinned-card option keeps all detected IDs visible together while the active result remains unmistakable."),
                ReleaseNoteItem(label: "Present, never in the way", detail: "Markers ignore the mouse, clear when their source moves, respect Reduce Motion, and remain excluded from screen capture.")
            ]
        ),
        ReleaseNote(
            version: "1.0.0",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "Ready for the long run",
            headline: "Nuncid is ready to call 1.0.",
            intro: "The app you use and the release you download now travel with one dependable story—from the GitHub front door to the packaged card on your Mac.",
            items: [
                ReleaseNoteItem(label: "Always the current Nuncid", detail: "The install path follows the latest verified release, and automatic checks keep every public version reference in agreement."),
                ReleaseNoteItem(label: "A clear first launch", detail: "Nuncid explains its signing status honestly, with an optional Developer ID and notarization path ready when credentials are available."),
                ReleaseNoteItem(label: "Proof that travels", detail: "Packaged smoke tests now work away from the source folder, alongside focused release checks that report drift clearly."),
                ReleaseNoteItem(label: "Checked before it lands", detail: "Every pull request builds, tests, packages, verifies its signature, and checks release metadata on a real macOS runner."),
                ReleaseNoteItem(label: "A current front door", detail: "GitHub now shows the released card controls, Settings, Version History, and product story exactly as they appear in 1.0.")
            ]
        ),
        ReleaseNote(
            version: "0.5.3",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "A steady return",
            headline: "Your pinned card comes back safely.",
            intro: "Nuncid now lets app startup settle before restoring a saved pinned card, keeping every return to your workspace dependable.",
            items: [
                ReleaseNoteItem(label: "A calm launch", detail: "The restored card appears just after startup instead of competing with the interface while it is still being created."),
                ReleaseNoteItem(label: "Right where you left it", detail: "Your remembered pin state, position, size, project, and result remain ready for the next session."),
                ReleaseNoteItem(label: "Your choice stays yours", detail: "Restore pinned remains enabled when you chose it; the safer timing needs no preference reset or workaround.")
            ]
        ),
        ReleaseNote(
            version: "0.5.2",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "One continuous rail",
            headline: "Scroll through tickets as one continuous list.",
            intro: "Every visible result now follows the wheel together while the primary card remains calmly anchored at the center.",
            items: [
                ReleaseNoteItem(label: "One clear direction", detail: "Scroll up and every row moves upward; scroll down and the entire rail reverses naturally."),
                ReleaseNoteItem(label: "No wrong-way entry", detail: "New Previous results no longer drop down from the top against the rest of the list."),
                ReleaseNoteItem(label: "Wheel or click", detail: "Close directly or use quiet arrows for projects and results; centered pin and position status keeps you oriented."),
                ReleaseNoteItem(label: "The card still stands out", detail: "The primary card stays fixed while the rail flows around it, with a quiet opacity change when Reduce Motion is enabled.")
            ]
        ),
        ReleaseNote(
            version: "0.5.1",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "Motion with meaning",
            headline: "Watch every ticket move exactly where it belongs.",
            intro: "Scrolling now preserves visual identity: the ticket key and title travel between the spatial rail and the fixed card in one clean, continuous motion.",
            items: [
                ReleaseNoteItem(label: "Follow the result", detail: "The next ticket’s key and first title line glide into the card while the previous selection moves back into the rail."),
                ReleaseNoteItem(label: "Nothing jumps", detail: "The card and its title area reserve stable space across every result, so different content lengths never push the interface around."),
                ReleaseNoteItem(label: "Words land first", detail: "Long titles stay on one line while moving, then reveal their wrapped lines only after reaching the card."),
                ReleaseNoteItem(label: "Calm when requested", detail: "Reduce Motion keeps the same orientation with a quiet opacity change instead of spatial movement.")
            ]
        ),
        ReleaseNote(
            version: "0.5.0",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "Spatial navigation",
            headline: "Keep your place while tickets move around you.",
            intro: "Nuncid’s popup is now a calm, direct navigator: enter it without a race, pin or resize it in place, and browse nearby results from wherever you are working.",
            items: [
                ReleaseNoteItem(label: "Pin without chasing", detail: "The temporary card waits while you move into it, stays open under the pointer, and offers its own pin button; the pinned card can be unpinned just as directly."),
                ReleaseNoteItem(label: "A card that fits", detail: "Resize from any edge or corner. Nuncid remembers the custom dimensions, position, and pin state, and Settings shows the saved Custom size."),
                ReleaseNoteItem(label: "Know every scroll", detail: "Previous and next tickets move around a fixed primary card, with clearer IDs and animated spatial continuity."),
                ReleaseNoteItem(label: "Navigate from anywhere", detail: "Hold your chosen modifier to browse while another app remains active, or scroll normally whenever the pointer is inside the popup."),
                ReleaseNoteItem(label: "Open the real source", detail: "The quiet source label is now a direct link to its Paimos or GitHub record."),
                ReleaseNoteItem(label: "Function keys welcome", detail: "Record F1 through F20—including F19—as standalone global shortcuts for activation or the pinned card.")
            ]
        ),
        ReleaseNote(
            version: "0.4.0",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "Meet Nuncid",
            headline: "A clearer name for context, identified now.",
            intro: "GLINT is now Nuncid (NUN-sid)—the same private ticket companion, with one distinct identity across the app, project, and repository.",
            items: [
                ReleaseNoteItem(label: "Same trusted app", detail: "Your shortcuts, activation and card preferences, learned context, and Screen Recording access carry forward."),
                ReleaseNoteItem(label: "One clear identity", detail: "The app, package, repository, and active Paimos project now share the Nuncid name."),
                ReleaseNoteItem(label: "History stays true", detail: "Earlier GLINT releases and GLINT-* ticket references remain intact and continue to resolve."),
                ReleaseNoteItem(label: "Private by design", detail: "Nuncid keeps scanning local to your Mac and performs read-only ticket lookups, so your workflow stays private and focused.")
            ]
        ),
        ReleaseNote(
            version: "0.3.3",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "A clearer story",
            headline: "See what gets better, release by release.",
            intro: "GLINT now explains every update in clear, positive language—right inside the app.",
            items: [
                ReleaseNoteItem(label: "Easy to find", detail: "Open Version History from the menu, About window, or the version in Settings."),
                ReleaseNoteItem(label: "Quick to scan", detail: "Every release leads with the benefit, followed by short details that matter in everyday use."),
                ReleaseNoteItem(label: "Always oriented", detail: "Your running version is highlighted, so you immediately know what is new for you.")
            ]
        ),
        ReleaseNote(
            version: "0.3.2",
            isoDate: "2026-08-30",
            date: "30 August 2026",
            theme: "Activation",
            headline: "Scanning now does exactly what you expect.",
            intro: "Three clear choices replace the old overlapping hover behaviors, with visible status whenever hands-free scanning is active.",
            items: [
                ReleaseNoteItem(label: "Clear choices", detail: "Choose Off, Toggle Hover, or Press to Scan."),
                ReleaseNoteItem(label: "Calm hover", detail: "A settled pointer location is scanned once instead of restarting in a loop."),
                ReleaseNoteItem(label: "Visible status", detail: "The menu bar icon shows when hover is on and confirms when GLINT finds a ticket."),
                ReleaseNoteItem(label: "Tidier Settings", detail: "Your setup is summarized one item at a time, without a distracting scrollbar.")
            ]
        ),
        ReleaseNote(
            version: "0.3.1",
            isoDate: "2026-08-29",
            date: "29 August 2026",
            theme: "Open source",
            headline: "GLINT is open and easier to explore.",
            intro: "The project is now published under the GNU AGPL v3.0 with a refreshed public home on GitHub.",
            items: [
                ReleaseNoteItem(label: "Open by design", detail: "Read, learn from, and improve the source under a strong free-software license."),
                ReleaseNoteItem(label: "A better front door", detail: "Updated visuals and documentation make the workflow easier to understand before installing.")
            ]
        ),
        ReleaseNote(
            version: "0.3.0",
            isoDate: "2026-08-29",
            date: "29 August 2026",
            theme: "Everyday flow",
            headline: "Ticket context feels immediate and personal.",
            intro: "GLINT became a polished daily companion with anchored feedback, smarter matching, and cards that adapt to you.",
            items: [
                ReleaseNoteItem(label: "See the scan", detail: "Subtle on-screen cues show where GLINT is looking and which ticket it recognized."),
                ReleaseNoteItem(label: "Trust the result", detail: "Evidence-ranked resolution favors real, relevant records across connected trackers."),
                ReleaseNoteItem(label: "Make it yours", detail: "Tune card size, density, surface, and alternative previews in Settings.")
            ]
        ),
        ReleaseNote(
            version: "0.2.2",
            isoDate: "2026-08-29",
            date: "29 August 2026",
            theme: "Settings",
            headline: "Everything important has a clear home.",
            intro: "Settings were reorganized into focused panes with native controls and plain-language guidance.",
            items: [
                ReleaseNoteItem(label: "Easy navigation", detail: "General, Shortcuts, and Privacy are separated into calm, focused pages."),
                ReleaseNoteItem(label: "Immediate confidence", detail: "Changes apply as you make them, with visible feedback and straightforward defaults.")
            ]
        ),
        ReleaseNote(
            version: "0.2.1",
            isoDate: "2026-08-28",
            date: "28 August 2026",
            theme: "Reliability",
            headline: "The pinned navigator stays in your rhythm.",
            intro: "Focus handling is more dependable, so keyboard entry and navigation remain with the ticket card when you need them.",
            items: [
                ReleaseNoteItem(label: "Steady focus", detail: "Pinned-card interaction remains reliable while moving between results and projects."),
                ReleaseNoteItem(label: "Safer changes", detail: "Expanded regression checks protect the navigator’s most important state transitions.")
            ]
        ),
        ReleaseNote(
            version: "0.2.0",
            isoDate: "2026-08-28",
            date: "28 August 2026",
            theme: "Navigator",
            headline: "Point, inspect, and keep the right ticket close.",
            intro: "GLINT grew from a quick lookup into a flexible ticket navigator that can stay on screen while you work.",
            items: [
                ReleaseNoteItem(label: "Richer context", detail: "The primary card shows useful ticket detail with nearby alternatives ready to browse."),
                ReleaseNoteItem(label: "Pinned when useful", detail: "Keep a result visible, move it between screens, and navigate with the wheel or keyboard."),
                ReleaseNoteItem(label: "Your shortcuts", detail: "Choose global shortcuts for inspecting and opening the pinned card.")
            ]
        ),
        ReleaseNote(
            version: "0.1.0",
            isoDate: "2026-08-28",
            date: "28 August 2026",
            theme: "First release",
            headline: "Ticket context, right where you point.",
            intro: "The first GLINT release turned a ticket key on screen into a real tracker record without interrupting your work.",
            items: [
                ReleaseNoteItem(label: "Local understanding", detail: "Apple Vision reads only a small region beneath the pointer, entirely on your Mac."),
                ReleaseNoteItem(label: "Real records", detail: "Read-only lookups connect visible keys to PPM, PMA, and GitHub."),
                ReleaseNoteItem(label: "No invented answers", detail: "When a record cannot be verified, GLINT does not fill the gap with a placeholder.")
            ]
        )
    ]

    static func isValid(currentVersion: String) -> Bool {
        let versions = notes.map(\.version)
        return !notes.isEmpty
            && Set(versions).count == versions.count
            && versions.first == currentVersion
            && notes.allSatisfy { !$0.headline.isEmpty && !$0.intro.isEmpty && !$0.items.isEmpty }
    }
}

struct VersionHistoryView: View {
    let currentVersion: String
    @State private var selectedVersion: String

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        _selectedVersion = State(initialValue: ReleaseHistory.notes.first(where: { $0.version == currentVersion })?.version ?? ReleaseHistory.notes.first?.version ?? "")
    }

    private var selectedNote: ReleaseNote? {
        ReleaseHistory.notes.first(where: { $0.version == selectedVersion })
    }

    var body: some View {
        HStack(spacing: 0) {
            versionRail
            Divider()
            detail
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var versionRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Version History", systemImage: "clock.arrow.circlepath")
                    .font(.title2.weight(.bold))
                Text("What’s new in Nuncid")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 15)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(ReleaseHistory.notes) { note in
                        versionButton(note)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Running").font(.caption).foregroundStyle(.secondary)
                    VersionText(version: currentVersion, scheme: NuncidBrand.versionScheme, prefix: "v", size: 11)
                }
            }
            .padding(18)
        }
        .frame(width: 210)
        .background(VersionRailMaterial())
    }

    private func versionButton(_ note: ReleaseNote) -> some View {
        let selected = note.version == selectedVersion
        let current = note.version == currentVersion
        return Button {
            selectedVersion = note.version
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    VersionText(version: note.version, scheme: note.versionScheme, prefix: "v", size: 12,
                                weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        Text(note.date)
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                        if current {
                            Text("CURRENT")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor.opacity(0.45) : Color.clear))
        .accessibilityLabel("Version \(note.version)\(current ? ", current" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        if let note = selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: note.version == currentVersion ? "sparkles" : "checkmark.circle")
                            .font(.system(size: 24, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 42, height: 42)
                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            VStack(alignment: .leading, spacing: 6) {
                                VersionText(version: note.version, scheme: note.versionScheme, prefix: "v", size: 20, weight: .bold)
                                Text(note.theme.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .tracking(0.7)
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(note.date).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 24)

                    Text(note.headline)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(note.intro)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 9)
                        .padding(.bottom, 26)

                    VStack(spacing: 0) {
                        ForEach(Array(note.items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24, height: 24)
                                    .background(Color.accentColor.opacity(0.09), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.label).font(.headline)
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 13)
                            if index < note.items.count - 1 { Divider().padding(.leading, 36) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.09)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(30)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct VersionRailMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
