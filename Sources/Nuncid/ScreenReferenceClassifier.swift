import Foundation

// Screenshot discovery is deliberately stricter than intentional pinned input.
// These are deterministic rule decisions, not probabilities.
enum ScreenReferenceCategory: String, Hashable, Sendable {
    case issue, pullRequest, workflowRun, unknown
    var title: String {
        switch self {
        case .issue: return "Issue"
        case .pullRequest: return "PR"
        case .workflowRun: return "Run"
        case .unknown: return "Reference"
        }
    }
}

enum ScreenReferenceDecision: Hashable, Sendable {
    case ignore
    case unresolved
    case lookup(CandidateSpec)
}

struct ClassifiedScreenReference: Hashable, Sendable {
    let token: NearbyToken
    let category: ScreenReferenceCategory
    let decision: ScreenReferenceDecision
    let reason: String

    var spec: CandidateSpec? {
        if case let .lookup(spec) = decision { return spec }
        return nil
    }
    var isVisibleCandidate: Bool { decision != .ignore }
}

enum ScreenReferenceClassifier {
    static let maximumFragments = 256
    static let maximumCharactersPerFragment = 2_048
    static let maximumReferences = 512
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let url = regex(#"(?i)https?://github\.com/([a-z0-9-]+/[a-z0-9_.-]+)/(pull|actions/runs)/([0-9]+)(?![\w.-])"#)
    private static let issueURL = regex(#"(?i)https?://([^/\s]+)/issues/([a-z][a-z0-9]{1,11})-([0-9]+)(?![\w.-])"#)
    private static let label = regex(#"(?i)(?<![\w-])(?:release-)?(PR|pull[ -]+request|ticket|issue)\s*(?:number\s*|no\.?\s*|[:#]\s*)?([0-9]+)(?![\w]|\.[0-9])"#)
    private static let words = regex(#"'[^']*'|"[^"]*"|[;&|\n]|[^\s;&|]+"#)
    private static let inheritedLabel = regex(#"(?i)(?:\bgh\s+(?:pr|run)\s+view|\bPR|\bpull[ -]+request|\bticket|\bissue)\s*[:#]?\s*$"#)
    private static let startsNumber = regex(#"^\s*#?[0-9]+\b"#)
    private static let repoFlag = regex(#"(?:^|\s)(?:--repo(?:=|\s+)|-R\s*)([^\s;&|]+)"#)
    private static let repoURL = regex(#"(?i)https?://github\.com/([a-z0-9-]+/[a-z0-9_.-]+)"#)
    private static let slug = regex(#"(?<![\w./-])([A-Za-z0-9-]+/[A-Za-z0-9_.-]+)(?![\w./-])"#)
    private static let project = regex("\\b(?:" + (CandidatePlanner.ppmProjects.union(CandidatePlanner.pmaProjects)).sorted().joined(separator: "|") + ")\\b")
    private static let projectNumber = regex("\\b(" + (CandidatePlanner.ppmProjects.union(CandidatePlanner.pmaProjects)).sorted().joined(separator: "|") + ")\\s+#?([0-9]+)(?![\\w]|\\.[0-9])")

    private struct Noise {
        let pattern: NSRegularExpression
        let reason: String
    }
    // Containers protect every numeric component, including malformed/partial
    // identifiers inside filenames and machine metadata. Typed URLs/commands
    // are recognized first, not executed.
    private static let containers: [Noise] = [
        .init(pattern: regex(#"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+"#), reason: "unsupported URL component"),
        .init(pattern: regex(#"(?<!\w)(?:[~/]|\.{1,2}/|[A-Za-z]:\\)[^\s<>"']+|(?<![\w/])(?:[\w.-]+/)+[\w.-]+"#), reason: "filesystem/repository path component"),
        .init(pattern: regex(#"(?i)\b(?:gpt|claude|gemini|llama|qwen|batch|round|runde)[- ]+[0-9]+(?:[\w.-]*)"#), reason: "model, batch or round label"),
        .init(pattern: regex(#"(?i)(?:["'][a-z_][a-z0-9_]*["']|\b(?:id|[a-z_]+_id|[a-z_]*count|rate_hourly))\s*:\s*-?[0-9]+(?:\.[0-9]+)?"#), reason: "structural field value, not a ticket key")
    ]
    private static let numericNoise: [Noise] = [
        .init(pattern: regex(#"\b[0-9]{1,4}([./-])[0-9]{1,2}\1[0-9]{1,4}\b"#), reason: "date"),
        .init(pattern: regex(#"\b[0-9]{1,2}:[0-9]{1,2}(?::[0-9]{1,2})?\b"#), reason: "time"),
        .init(pattern: regex(#"[0-9]+(?:[.,][0-9]+)*\s*%"#), reason: "percentage"),
        .init(pattern: regex(#"[$€£]\s*[0-9]+(?:[.,][0-9]+)*|[0-9]+(?:[.,][0-9]+)+"#), reason: "amount, rate or decimal/version component"),
        .init(pattern: regex(#"(?i)\b[0-9]+(?:[.,][0-9]+)?\s*(?:k|m|ms|s|sec(?:onds?)?|min(?:utes?)?|h|hours?|d|days?|bytes?|kb|mb|gb|tokens?|lines?|shells?|entries|agents?|terminals?|jobs?|runs?|checks?|tests?|requests?|items?|workers?|commits?)\b"#), reason: "quantity, metric or duration"),
        .init(pattern: regex(#"(?i)\b[0-9]+\s+(?:(?:background|knowledge|active|pending|remaining|parallel|running)\s+){1,3}(?:entries|agents?|terminals?|jobs?|workers?|tests?|shells?)\b"#), reason: "count"),
        .init(pattern: regex(#"(?i)\b(?:round|runde|batch|main|reference_count|count)\s*[:+]?\s*[0-9]+\b"#), reason: "counter"),
        .init(pattern: regex(#"(?<!\S)--?[\w-]+(?:=[^\s]+)?|\[\s*[0-9]+\s*\]"#), reason: "command option or array index")
    ]

    private struct Word {
        let text: String
        let range: NSRange
    }
    private struct Command {
        let category: ScreenReferenceCategory
        let number: Word
        let scope: [String]
        let invalidScope: Bool
        let span: NSRange
    }

    static func classify(_ input: OCRContextInput) -> [ClassifiedScreenReference] {
        let fragments = Array(input.fragments.prefix(maximumFragments)).map { fragment in
            guard (fragment.text as NSString).length > maximumCharactersPerFragment else { return fragment }
            return OCRContextFragment(text: "", lineIndex: fragment.lineIndex, order: fragment.order,
                confidence: fragment.confidence, region: fragment.region, contextGroup: fragment.contextGroup)
        }
        let bounded = OCRContextInput(fragments: fragments)
        let tokens = Dictionary(grouping: TokenParser.parse(bounded), by: \.fragmentIndex)
        var result: [ClassifiedScreenReference] = []
        for (index, fragment) in fragments.enumerated() {
            guard (fragment.text as NSString).length <= maximumCharactersPerFragment else { continue }
            let neighbors = contextNeighbors(of: index, in: fragments)
            // A split `PR | 42` or wrapped `gh run view / 123` may inherit only
            // an attached terminal cue, never arbitrary nearby PR language.
            let predecessor = neighbors.filter { isBefore($0, fragment) && inheritedLabel.firstMatch(in: $0.text, range: fullRange($0.text)) != nil }.first
            let prefix = startsNumber.firstMatch(in: fragment.text, range: fullRange(fragment.text)) != nil ? predecessor.map { $0.text + " " } ?? "" : ""
            let text = prefix + fragment.text
            let offset = (prefix as NSString).length
            let ns = text as NSString
            let commandValues = commands(in: text)
            let protected = spans(containers, in: text)
            let numbers = spans(numericNoise, in: text)
            var covered: [NSRange] = []

            func token(_ range: NSRange, kind: NearbyToken.Kind) -> NearbyToken? {
                guard range.location >= offset, NSMaxRange(range) <= ns.length else { return nil }
                let local = NSRange(location: range.location - offset, length: range.length)
                return NearbyToken(raw: ns.substring(with: range), kind: kind,
                    sourceOrder: fragment.order * 1_000_000 + local.location,
                    fragmentIndex: index, lineIndex: fragment.lineIndex, characterOffset: local.location,
                    confidence: fragment.confidence, region: fragment.region)
            }
            func append(_ range: NSRange, kind: NearbyToken.Kind, category: ScreenReferenceCategory,
                        decision: ScreenReferenceDecision, reason: String) {
                guard !covered.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      let found = token(range, kind: kind) else { return }
                covered.append(range)
                result.append(ClassifiedScreenReference(token: found, category: category, decision: decision, reason: reason))
            }
            func resolve(_ range: NSRange, category: ScreenReferenceCategory, number: Int, scopes: [String], invalid: Bool, reason: String) {
                let unique = Set(scopes)
                let spec: CandidateSpec?
                if !invalid, unique.count == 1, let scope = unique.first, number > 0 {
                    switch category {
                    case .workflowRun: spec = .workflowRun(id: number, repo: scope)
                    case .pullRequest: spec = .pullRequest(number: number, repo: scope)
                    case .issue:
                        spec = .issue(tracker: CandidatePlanner.pmaProjects.contains(scope) ? .pma : .ppm, key: "\(scope)-\(number)")
                    case .unknown: spec = nil
                    }
                } else { spec = nil }
                append(range, kind: .bareNumber(number), category: category,
                       decision: number <= 0 ? .ignore : spec.map(ScreenReferenceDecision.lookup) ?? .unresolved,
                       reason: spec == nil ? (invalid || unique.count > 1 ? "Conflicting or invalid scope" : "\(category == .issue ? "Project" : "Repository") needed") : reason)
            }

            for match in issueURL.matches(in: text, range: fullRange(text)) {
                guard let tracker = CandidatePlanner.issueURLTrackers[ns.substring(with: match.range(at: 1)).lowercased()],
                      let number = Int(ns.substring(with: match.range(at: 3))), number > 0 else { continue }
                let project = ns.substring(with: match.range(at: 2)).uppercased()
                let range = NSRange(location: match.range(at: 2).location, length: NSMaxRange(match.range(at: 3)) - match.range(at: 2).location)
                append(range, kind: .issueKey(project: project, number: number), category: .issue,
                       decision: .lookup(.issue(tracker: tracker, key: "\(project)-\(number)")), reason: "Explicit Paimos issue URL")
            }
            for match in url.matches(in: text, range: fullRange(text)) {
                let numberRange = match.range(at: 3)
                guard let number = Int(ns.substring(with: numberRange)) else { continue }
                let repo = CandidatePlanner.validatedGitHubRepo(ns.substring(with: match.range(at: 1)))
                resolve(numberRange, category: ns.substring(with: match.range(at: 2)).lowercased() == "pull" ? .pullRequest : .workflowRun,
                        number: number, scopes: repo.map { [$0] } ?? [], invalid: repo == nil, reason: "Explicit GitHub reference URL")
            }
            for command in commandValues {
                guard let number = Int(command.number.text) else { continue }
                let inferred = repositoryScopes(in: neighbors.map(\.text))
                resolve(command.number.range, category: command.category, number: number,
                        scopes: command.scope.isEmpty && !command.invalidScope ? inferred.scopes : command.scope,
                        invalid: command.invalidScope || (command.scope.isEmpty && inferred.invalid), reason: "Explicit gh \(command.category == .workflowRun ? "run" : "pr") view command")
            }
            // A known explicit issue key can contain a long number; numeric/hash
            // heuristics must not reinterpret that key. Paths/compound names still win.
            for original in tokens[index] ?? [] {
                guard case let .issueKey(project, number) = original.kind else { continue }
                let range = NSRange(location: original.characterOffset + offset, length: (original.raw as NSString).length)
                let inCommand = commandValues.contains { NSIntersectionRange($0.span, range).length > 0 }
                let suffix = ns.substring(from: NSMaxRange(range))
                let compound = suffix.hasPrefix("-") || suffix.range(of: #"^\.[A-Za-z0-9]"#, options: .regularExpression) != nil
                if let noise = overlaps(range, protected), !inCommand {
                    append(range, kind: original.kind, category: .issue, decision: .ignore, reason: noise)
                } else if compound || inCommand {
                    append(range, kind: original.kind, category: .issue, decision: .ignore, reason: "Compound name or command argument")
                } else if CandidatePlanner.ppmProjects.contains(project) || CandidatePlanner.pmaProjects.contains(project) {
                    append(range, kind: original.kind, category: .issue,
                           decision: number > 0 ? .lookup(.issue(tracker: CandidatePlanner.pmaProjects.contains(project) ? .pma : .ppm, key: "\(project)-\(number)")) : .ignore,
                           reason: "Explicit \(project) issue key")
                } else {
                    append(range, kind: original.kind, category: .issue, decision: .unresolved, reason: "Project routing needed")
                }
            }
            for pattern in [label, projectNumber] {
                for match in pattern.matches(in: text, range: fullRange(text)) {
                    let range = match.range(at: 2)
                    guard let number = Int(ns.substring(with: range)) else { continue }
                    if let noise = overlaps(range, protected + numbers) {
                        append(range, kind: .bareNumber(number), category: .unknown, decision: .ignore, reason: noise)
                        continue
                    }
                    let cue = ns.substring(with: match.range(at: 1))
                    let category: ScreenReferenceCategory = cue.lowercased() == "pr" || cue.lowercased().hasPrefix("pull") ? .pullRequest : .issue
                    let start = max(0, range.location - 100)
                    let local = ns.substring(with: NSRange(location: start, length: min(ns.length, NSMaxRange(range) + 100) - start))
                    let context = [local] + neighbors.map(\.text)
                    if category == .pullRequest {
                        let repos = repositoryScopes(in: context)
                        resolve(range, category: category, number: number, scopes: repos.scopes, invalid: repos.invalid, reason: "Attached PR label and local repository context")
                    } else {
                        let projects = context.flatMap { line in
                            project.matches(in: line, range: fullRange(line)).map { (line as NSString).substring(with: $0.range) }
                        }
                        resolve(range, category: category, number: number, scopes: projects, invalid: false, reason: "Attached issue label and local project context")
                    }
                }
            }
            for original in tokens[index] ?? [] {
                let range = NSRange(location: original.characterOffset + offset, length: (original.raw as NSString).length)
                let noise = overlaps(range, protected + numbers)
                let inCommand = commandValues.contains { NSIntersectionRange($0.span, range).length > 0 }
                let ambiguousHash: Bool
                if case let .hashNumber(number) = original.kind { ambiguousHash = number > 0 && noise == nil && !inCommand }
                else { ambiguousHash = false }
                append(range, kind: original.kind, category: .unknown,
                       decision: ambiguousHash ? .unresolved : .ignore,
                       reason: noise ?? (ambiguousHash ? "Reference type and scope needed" : "No local reference evidence"))
            }
            if result.count >= maximumReferences { break }
        }
        return Array(result.sorted { $0.token.sourceOrder < $1.token.sourceOrder }.prefix(maximumReferences))
    }

    private static func commands(in text: String) -> [Command] {
        let ns = text as NSString
        let parts = words.matches(in: text, range: fullRange(text)).map { Word(text: ns.substring(with: $0.range), range: $0.range) }
        var result: [Command] = []
        for start in parts.indices where parts[start].text == "gh" {
            var i = start + 1
            var repos: [String] = []
            var invalid = false
            func takeRepo() -> Bool {
                guard i < parts.count else { return false }
                let word = parts[i].text
                var raw: String?
                if word == "--repo" || word == "-R" {
                    i += 1
                    if i < parts.count { raw = parts[i].text } else { invalid = true }
                } else if word.hasPrefix("--repo=") { raw = String(word.dropFirst(7)) }
                else if word.hasPrefix("-R"), word.count > 2 { raw = String(word.dropFirst(2)) }
                else { return false }
                if let raw, let repo = CandidatePlanner.validatedGitHubRepo(unquote(raw)) { repos.append(repo) }
                else { invalid = true }
                i += 1
                return true
            }
            while takeRepo() {}
            guard i + 1 < parts.count, ["pr", "run"].contains(parts[i].text), parts[i + 1].text == "view" else { continue }
            let category: ScreenReferenceCategory = parts[i].text == "run" ? .workflowRun : .pullRequest
            i += 2
            var ids: [Word] = []
            var unsupported = false
            while i < parts.count, ![";", "|", "&", "\n"].contains(parts[i].text) {
                if takeRepo() { continue }
                let word = parts[i].text
                if ["--json", "--jq", "-q", "--template", "-t", "--attempt"].contains(word) { i += 2; continue }
                if word.hasPrefix("--json=") || word.hasPrefix("--jq=") || word.hasPrefix("--attempt=") { i += 1; continue }
                if ["--web", "-w", "--comments", "-c", "--log", "--log-failed", "--verbose", "--exit-status"].contains(word) { i += 1; continue }
                if word.hasPrefix("-") { unsupported = true; i += 1; continue }
                if !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isNumber }) { ids.append(parts[i]) }
                i += 1
            }
            let end = i < parts.count ? parts[i].range.location : ns.length
            if ids.count == 1, !unsupported {
                result.append(Command(category: category, number: ids[0], scope: repos, invalidScope: invalid,
                    span: NSRange(location: parts[start].range.location, length: end - parts[start].range.location)))
            }
        }
        return result
    }

    private static func repositoryScopes(in lines: [String]) -> (scopes: [String], invalid: Bool) {
        var repos: [String] = []
        var invalid = false
        let canonical = Set(CandidatePlanner.ppmProjects.union(CandidatePlanner.pmaProjects).compactMap { CandidatePlanner.repo(for: $0) })
        for line in lines {
            let ns = line as NSString
            for match in repoFlag.matches(in: line, range: fullRange(line)) {
                if let repo = CandidatePlanner.validatedGitHubRepo(unquote(ns.substring(with: match.range(at: 1)))) { repos.append(repo) }
                else { invalid = true }
            }
            for match in repoURL.matches(in: line, range: fullRange(line)) {
                if let repo = CandidatePlanner.validatedGitHubRepo(ns.substring(with: match.range(at: 1))) { repos.append(repo) }
            }
            for match in slug.matches(in: line, range: fullRange(line)) {
                let raw = ns.substring(with: match.range(at: 1)).lowercased()
                if canonical.contains(raw) { repos.append(raw) }
            }
            for match in project.matches(in: line, range: fullRange(line)) {
                if let repo = CandidatePlanner.repo(for: ns.substring(with: match.range)) { repos.append(repo) }
            }
        }
        return (repos, invalid)
    }

    private static func contextNeighbors(of index: Int, in fragments: [OCRContextFragment]) -> [OCRContextFragment] {
        let target = fragments[index]
        var sameRow: [OCRContextFragment] = []
        var above: (OCRContextFragment, Double)?
        var below: (OCRContextFragment, Double)?
        for (otherIndex, other) in fragments.enumerated() where otherIndex != index && other.contextGroup == target.contextGroup {
            guard (other.text as NSString).length <= maximumCharactersPerFragment else { continue }
            guard let a = target.region, let b = other.region else {
                if target.region == nil, other.region == nil, abs(other.lineIndex - target.lineIndex) == 1 {
                    if other.lineIndex < target.lineIndex { above = (other, 1) } else { below = (other, 1) }
                }
                continue
            }
            let h = max(a.height, b.height)
            guard h > 0 else { continue }
            let vertical = abs((a.y + a.height / 2) - (b.y + b.height / 2))
            let charWidth = max(a.width / Double(max(1, target.text.count)), b.width / Double(max(1, other.text.count)))
            let horizontal = max(0, max(a.x, b.x) - min(a.x + a.width, b.x + b.width))
            if vertical <= h * 0.4, horizontal <= min(0.04, charWidth * 3) { sameRow.append(other); continue }
            let overlap = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
            guard vertical > h * 0.4, vertical <= h * 2.2,
                  abs(a.x - b.x) <= min(0.05, charWidth * 4),
                  overlap >= min(a.width, b.width) * 0.6 else { continue }
            if b.y > a.y, above == nil || vertical < above!.1 { above = (other, vertical) }
            if b.y < a.y, below == nil || vertical < below!.1 { below = (other, vertical) }
        }
        return sameRow.sorted { ($0.region?.x ?? 0) < ($1.region?.x ?? 0) } + [above?.0, below?.0].compactMap { $0 }
    }

    private static func isBefore(_ other: OCRContextFragment, _ target: OCRContextFragment) -> Bool {
        if let a = other.region, let b = target.region {
            return a.y > b.y + b.height * 0.4 || (abs(a.y - b.y) < b.height * 0.4 && a.x < b.x)
        }
        return other.lineIndex < target.lineIndex
    }
    private static func fullRange(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }
    private static func unquote(_ text: String) -> String {
        if text.count >= 2, (text.first == "\"" && text.last == "\"") || (text.first == "'" && text.last == "'") { return String(text.dropFirst().dropLast()) }
        return text
    }
    private static func spans(_ rules: [Noise], in text: String) -> [(NSRange, String)] {
        rules.flatMap { rule in rule.pattern.matches(in: text, range: fullRange(text)).map { ($0.range, rule.reason) } }
    }
    private static func overlaps(_ range: NSRange, _ spans: [(NSRange, String)]) -> String? {
        spans.first { NSIntersectionRange(range, $0.0).length > 0 }?.1
    }
}
