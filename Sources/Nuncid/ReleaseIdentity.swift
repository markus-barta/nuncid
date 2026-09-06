import Foundation

/// The two version schemes Nuncid can encounter, as explicit tagged values.
/// Tooling MUST NOT infer a scheme from punctuation or segment count: strings
/// such as `26.11.11` are syntactically plausible under more than one scheme.
enum VersionScheme: String, Equatable, Sendable {
    case legacy = "legacy"
    case calendar = "inspr-calendar-v1"

    static func parse(_ raw: String) -> VersionScheme? {
        [VersionScheme.legacy, .calendar].first { $0.rawValue == raw }
    }
}

/// A validated `inspr-calendar-v1` coordinate: `YY.MM.DD` or
/// `YY.MM.DD.hh.mm.ss`, UTC, fixed-width, real proleptic-Gregorian date.
struct CalendarVersion: Equatable, Comparable, Sendable {
    let year: Int      // 2000...2099
    let month: Int     // 1...12
    let day: Int
    let hour: Int      // 0 when short form (normalizes to 00.00.00)
    let minute: Int
    let second: Int
    let longForm: Bool
    let raw: String

    init?(_ raw: String) {
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        let width = components.count == 3 ? 3 : (components.count == 6 ? 6 : 0)
        guard width != 0, components.allSatisfy({ component in
            component.count == 2 && component.allSatisfy({ $0.isASCII && $0.isNumber })
        }) else { return nil }
        guard let yy = Int(components[0]),
              let mm = Int(components[1]),
              let dd = Int(components[2]),
              (1...12).contains(mm) else { return nil }
        let longForm = width == 6
        guard let hh = longForm ? Int(components[3]) : 0,
              let mi = longForm ? Int(components[4]) : 0,
              let ss = longForm ? Int(components[5]) : 0 else { return nil }
        guard (0...23).contains(hh), (0...59).contains(mi), (0...59).contains(ss) else { return nil }
        let year = 2000 + yy
        guard (1...Self.daysInMonth(year, mm)).contains(dd) else { return nil }
        self.year = year
        self.month = mm
        self.day = dd
        self.hour = hh
        self.minute = mi
        self.second = ss
        self.longForm = longForm
        self.raw = raw
    }

    var canonical: String {
        if longForm {
            return String(format: "%02d.%02d.%02d.%02d.%02d.%02d", year - 2000, month, day, hour, minute, second)
        }
        return String(format: "%02d.%02d.%02d", year - 2000, month, day)
    }

    /// The six normalized integer fields, compared in order.
    private var fields: [Int] { [year, month, day, hour, minute, second] }

    static func == (lhs: CalendarVersion, rhs: CalendarVersion) -> Bool {
        lhs.fields == rhs.fields
    }

    static func < (lhs: CalendarVersion, rhs: CalendarVersion) -> Bool {
        lhs.fields.lexicographicallyPrecedes(rhs.fields)
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leapYear ? 29 : 28
        }
    }
}

/// The immutable anchor of Nuncid's migration to `inspr-calendar-v1`
/// (NUNCID-58). Raw legacy and calendar strings are compared only within
/// their own scheme; cross-era ordering comes from this anchor, never from
/// SemVer comparison, lexical guesswork, or coercion of calendar fields.
enum ReleaseMigration {
    static let channel = "stable"
    static let lastLegacyVersion = "1.2.3"
    // Lower bound, NOT a reserved first-calendar coordinate. The bridge is
    // still SemVer; the calendar candidate must record its actual reservation.
    static let calendarNotBefore = "26.09.06"
    static let firstCalendarSequence = 20
    static let legacyVersions = [
        "0.1.0", "0.2.0", "0.2.1", "0.2.2", "0.3.0", "0.3.1",
        "0.3.2", "0.3.3", "0.4.0", "0.5.0", "0.5.1", "0.5.2",
        "0.5.3", "1.0.0", "1.1.0", "1.2.0", "1.2.1", "1.2.2", "1.2.3"
    ]
}

/// One version value with its explicit scheme, preserving the original
/// string. Construction fails closed on absent, unknown, ambiguous, or
/// invalid scheme data.
struct ReleaseIdentity: Equatable, Sendable {
    let scheme: VersionScheme
    let rawVersion: String
    let sequence: Int
    private(set) var calendar: CalendarVersion?
    private(set) var legacy: SemanticVersion?

    init?(rawVersion: String, scheme: VersionScheme, sequence: Int? = nil) {
        guard !rawVersion.isEmpty else { return nil }
        switch scheme {
        case .calendar:
            guard let calendar = CalendarVersion(rawVersion),
                  calendar >= CalendarVersion(ReleaseMigration.calendarNotBefore)!,
                  let sequence, sequence >= ReleaseMigration.firstCalendarSequence else { return nil }
            self.sequence = sequence
            self.scheme = .calendar
            self.rawVersion = rawVersion
            self.calendar = calendar
            self.legacy = nil
        case .legacy:
            guard let legacy = SemanticVersion(rawVersion),
                  let index = ReleaseMigration.legacyVersions.firstIndex(of: rawVersion),
                  sequence == nil || sequence == index + 1 else { return nil }
            self.sequence = index + 1
            self.scheme = .legacy
            self.rawVersion = rawVersion
            self.calendar = nil
            self.legacy = legacy
        }
    }

    /// Only the exact immutable legacy inventory can resolve absent metadata.
    /// Calendar strings NEVER acquire a scheme from their syntax.
    static func unclassified(_ rawVersion: String) -> ReleaseIdentity? {
        ReleaseIdentity(rawVersion: rawVersion, scheme: .legacy)
    }

    /// Whether this release is newer than `other`. Nil means indeterminate
    /// (fail closed): the caller must not offer an update on nil.
    func isNewerThan(_ other: ReleaseIdentity) -> Bool? {
        switch (scheme, other.scheme) {
        case (.calendar, .calendar):
            guard let selfCalendar = calendar, let otherCalendar = other.calendar else { return nil }
            guard (selfCalendar == otherCalendar && sequence == other.sequence)
                || (selfCalendar > otherCalendar && sequence > other.sequence)
                || (selfCalendar < otherCalendar && sequence < other.sequence) else { return nil }
            return selfCalendar > otherCalendar
        case (.legacy, .legacy):
            guard let selfLegacy = legacy, let otherLegacy = other.legacy else { return nil }
            return selfLegacy > otherLegacy
        case (.calendar, .legacy):
            return sequence >= ReleaseMigration.firstCalendarSequence && other.sequence < ReleaseMigration.firstCalendarSequence
        case (.legacy, .calendar):
            guard let otherIsNewer = other.isNewerThan(self) else { return nil }
            return !otherIsNewer
        }
    }

}