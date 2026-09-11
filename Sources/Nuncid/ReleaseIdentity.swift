import Foundation

/// The version schemes Nuncid can encounter, as explicit tagged values.
/// Tooling MUST NOT infer a scheme from punctuation or segment count: strings
/// such as `26.11.11` are syntactically plausible under more than one scheme.
enum VersionScheme: String, Equatable, Sendable {
    case legacy = "legacy"
    case calendar = "inspr-calendar-v1"
    case calendarV2 = "inspr-calendar-v2"

    static func parse(_ raw: String) -> VersionScheme? {
        [VersionScheme.legacy, .calendar, .calendarV2].first { $0.rawValue == raw }
    }
}

/// Fixed-width UTC calendar v2; SemVer syntax does not imply SemVer semantics.
struct CalendarVersionV2: Equatable, Comparable, Sendable {
    let raw: String
    let date: CalendarVersion
    let coordinate: UInt64

    init?(_ raw: String) {
        let bytes = Array(raw.utf8)
        guard bytes.count == 16, raw.hasSuffix(".0.0"),
              bytes.prefix(12).allSatisfy({ (48...57).contains($0) }),
              bytes[0] != 48,
              let coordinate = UInt64(String(raw.prefix(12))) else { return nil }
        let fields = stride(from: 0, to: 12, by: 2).map { String(decoding: bytes[$0..<($0 + 2)], as: UTF8.self) }
        guard let date = CalendarVersion(fields.joined(separator: ".")), date.year >= 2010 else { return nil }
        self.raw = raw; self.date = date; self.coordinate = coordinate
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.coordinate < rhs.coordinate }
    var macOSShortVersion: String { date.macOSShortVersion }

    static func fromMacOSShortVersion(_ raw: String) -> Self? {
        guard let date = CalendarVersion.fromMacOSShortVersion(raw), date.longForm else { return nil }
        return Self(date.raw.replacingOccurrences(of: ".", with: "") + ".0.0")
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

/// Runtime mirror of VERSION, validated by every producer. Calendar versions
/// remain canonical; macOS's three-component representation is never parsed
/// as SemVer or used for update ordering.
struct ReleaseBuildRecord: Decodable {
    let version_scheme: String
    let version: String
    let release_channel: String
    let release_sequence: Int
    let bundle_short_version: String
    let last_legacy_version: String
    let legacy_version_scheme: String?
    let first_calendar_version: String?
    let first_calendar_sequence: Int

    var identity: ReleaseIdentity? {
        guard release_channel == ReleaseMigration.channel,
              let scheme = VersionScheme.parse(version_scheme) else { return nil }
        if scheme == .calendar {
            guard let value = CalendarVersion(version),
                  value.macOSShortVersion == bundle_short_version,
                  last_legacy_version == ReleaseMigration.lastLegacyVersion,
                  first_calendar_sequence == ReleaseMigration.firstCalendarSequence,
                  let first = first_calendar_version.flatMap(CalendarVersion.init),
                  value >= first,
                  (release_sequence == first_calendar_sequence) == (version == first_calendar_version) else { return nil }
        } else if scheme == .calendarV2 {
            guard let value = CalendarVersionV2(version),
                  value.macOSShortVersion == bundle_short_version,
                  legacy_version_scheme == VersionScheme.calendar.rawValue,
                  last_legacy_version == ReleaseMigration.lastCalendarV1Version,
                  first_calendar_sequence == ReleaseMigration.firstCalendarV2Sequence,
                  let first = first_calendar_version.flatMap(CalendarVersionV2.init),
                  first.date > CalendarVersion(ReleaseMigration.lastCalendarV1Version)!,
                  value >= first,
                  (release_sequence == first_calendar_sequence) == (version == first_calendar_version) else { return nil }
        }
        return ReleaseIdentity(rawVersion: version, scheme: scheme, sequence: release_sequence)
    }
}

extension CalendarVersion {
    var macOSShortVersion: String {
        let clock = longForm ? hour * 3600 + minute * 60 + second + 1 : 0
        return "\(year).\(month * 100 + day).\(clock)"
    }

    static func fromMacOSShortVersion(_ raw: String) -> CalendarVersion? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && ($0.count == 1 || $0.first != "0") }),
              let year = Int(parts[0]), (2000...2099).contains(year),
              let monthDay = Int(parts[1]), (101...1231).contains(monthDay),
              let clock = Int(parts[2]), (0...86400).contains(clock) else { return nil }
        var canonical = String(format: "%02d.%02d.%02d", year - 2000, monthDay / 100, monthDay % 100)
        if clock > 0 {
            let second = clock - 1
            canonical += String(format: ".%02d.%02d.%02d", second / 3600, second / 60 % 60, second % 60)
        }
        guard let value = CalendarVersion(canonical), value.macOSShortVersion == raw else { return nil }
        return value
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
    static let lastCalendarV1Version = "26.09.11.10.11.21"
    static let firstCalendarV2Sequence = 26
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
    private(set) var calendarV2: CalendarVersionV2?
    private(set) var legacy: SemanticVersion?

    init?(rawVersion: String, scheme: VersionScheme, sequence: Int? = nil) {
        guard !rawVersion.isEmpty else { return nil }
        switch scheme {
        case .calendarV2:
            guard let value = CalendarVersionV2(rawVersion),
                  value.date > CalendarVersion(ReleaseMigration.lastCalendarV1Version)!,
                  let sequence, sequence >= ReleaseMigration.firstCalendarV2Sequence else { return nil }
            self.sequence = sequence; self.scheme = scheme; self.rawVersion = rawVersion
            self.calendarV2 = value
        case .calendar:
            guard let calendar = CalendarVersion(rawVersion),
                  calendar >= CalendarVersion(ReleaseMigration.calendarNotBefore)!,
                  calendar <= CalendarVersion(ReleaseMigration.lastCalendarV1Version)!,
                  let sequence, sequence >= ReleaseMigration.firstCalendarSequence,
                  sequence < ReleaseMigration.firstCalendarV2Sequence else { return nil }
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
        case (.calendarV2, .calendarV2):
            guard let lhs = calendarV2, let rhs = other.calendarV2,
                  (lhs == rhs && sequence == other.sequence)
                    || (lhs > rhs && sequence > other.sequence)
                    || (lhs < rhs && sequence < other.sequence) else { return nil }
            return lhs > rhs
        case (.calendarV2, _):
            return sequence >= ReleaseMigration.firstCalendarV2Sequence && other.sequence < ReleaseMigration.firstCalendarV2Sequence
        case (_, .calendarV2):
            return false
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
