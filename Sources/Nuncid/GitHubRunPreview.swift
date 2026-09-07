import Foundation

/// A run is a different GitHub entity from a PR, even when their numeric IDs
/// happen to match. No logs or artifacts are requested for this summary.
enum GitHubRunPreview {
    static func arguments(id: Int, repo: String) -> [String]? {
        guard id > 0, let repo = CandidatePlanner.validatedGitHubRepo(repo) else { return nil }
        return ["run", "view", String(id), "--repo", repo, "--json",
                "databaseId,workflowName,displayTitle,status,conclusion,headBranch,headSha,createdAt,startedAt,updatedAt,url,event"]
    }

    private struct Payload: Decodable {
        let databaseId: Int
        let workflowName: String?
        let displayTitle: String?
        let status: String
        let conclusion: String?
        let headBranch: String?
        let headSha: String?
        let createdAt: String?
        let startedAt: String?
        let updatedAt: String?
        let url: String
        let event: String?
    }

    static func line(data: Data, id: Int, repo: String) -> TicketLine? {
        guard let repo = CandidatePlanner.validatedGitHubRepo(repo),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.databaseId == id, id > 0,
              let url = URLComponents(string: payload.url), url.scheme == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath.lowercased() == "/\(repo)/actions/runs/\(id)" else { return nil }
        let title = nonempty(payload.displayTitle) ?? nonempty(payload.workflowName) ?? "Workflow run \(id)"
        let state = payload.status == "completed" ? nonempty(payload.conclusion) ?? "completed" : payload.status
        var metadata = [repo, "workflow run"]
        if let branch = nonempty(payload.headBranch) { metadata.append(branch) }
        if let sha = nonempty(payload.headSha) { metadata.append(String(sha.prefix(7))) }
        var detail = [nonempty(payload.workflowName), nonempty(payload.event)].compactMap { $0 }
        if payload.status == "completed", let start = date(payload.startedAt ?? payload.createdAt),
           let end = date(payload.updatedAt), end >= start {
            let seconds = Int(end.timeIntervalSince(start))
            detail.append("Duration \(seconds / 60)m \(seconds % 60)s")
        } else if let started = nonempty(payload.startedAt ?? payload.createdAt) {
            detail.append("Started \(started)")
        }
        return TicketLine(key: "Run \(id)", state: state.replacingOccurrences(of: "_", with: "-"),
                          title: title, source: "gh", metadata: metadata.joined(separator: " · "),
                          detail: detail.joined(separator: " · "), destination: payload.url,
                          identity: CandidateSpec.workflowRun(id: id, repo: repo).cacheKey)
    }

    static func cacheLifetime(for spec: CandidateSpec, line: TicketLine?) -> TimeInterval {
        guard let line else { return 60 }
        if case .workflowRun = spec {
            return ["queued", "in-progress", "waiting", "pending", "requested"].contains(line.state) ? 30 : 300
        }
        return 15 * 60
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
