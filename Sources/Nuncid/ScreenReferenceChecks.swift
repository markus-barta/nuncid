import Foundation

/// Synthetic fixtures only. No screenshot, private transcript or tracker call.
enum ScreenReferenceChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        func classify(_ text: String) -> [ClassifiedScreenReference] {
            ScreenReferenceClassifier.classify(OCRContextInput(lines: [text]))
        }
        func specs(_ text: String) -> [CandidateSpec] { classify(text).compactMap(\.spec) }
        let ignored = [
            "75% 100 % 85% 0% 51% 26% 35%",
            "07.09.2026, 10:10 CEST — ETA 11:00",
            "2026-09-01 06:50:22 and 18:08:06",
            "+5 lines (ctrl + t to view transcript)", "+2 lines", "+354 lines",
            "Prepared 8 knowledge entries", "1 background agent; 1 shell; 1 background terminal",
            "QA round 2; QA-Runde 2; main +16", "tail -2 /tmp/example-delivery-20260907/output.log",
            "gpt-6-astra", "Batch-2-PRs", "GPT-6", "claude-4-model",
            "/tmp/example-foundation-20260907-a1b2c3d", "Sources/Nuncid NUNCID-42.txt",
            #"{"id":8,"name":"INSPR","reference_count":0,"user_id":2}"#,
            #"{"id":30,"key":"START","issue_id":5186,"id":583}"#,
            "PR checks took 42 seconds", "PR #42% complete", "NUNCID 42 tokens",
            "510k/1.0M 592.30 6.67/h 2h02m 7d", "5.0M 415k 182M 99.4% $274.697",
            "abcdef1234567890", "34000001234", "Release-PR 1.8.0",
            "gh run view --job 9876 --repo example/project", "gh pr list --limit 20 --repo example/project"
        ]
        for text in ignored {
            check(classify(text).allSatisfy { !$0.isVisibleCandidate }, "ignore: \(text)")
        }
        check(specs("NUNCID-70") == [.issue(tracker: .ppm, key: "NUNCID-70")], "explicit Paimos key")
        check(specs("START-42") == [.issue(tracker: .pma, key: "START-42")], "explicit PMA route")
        check(specs("https://pm.barta.cm/issues/CUSTOM-42") == [.issue(tracker: .ppm, key: "CUSTOM-42")], "explicit Paimos URL scope")
        check(specs("https://github.com/example/project/pull/42") == [.pullRequest(number: 42, repo: "example/project")], "PR URL")
        check(specs("https://github.com/example/project/actions/runs/34000001234") == [.workflowRun(id: 34000001234, repo: "example/project")], "run URL")
        check(specs("gh run view 34000001234 --repo example/project --json jobs --jq '.jobs[0]' --attempt 2") == [.workflowRun(id: 34000001234, repo: "example/project")], "run argv and non-ID flag values")
        check(specs("gh --repo Example/Project run view 34000001234 --log") == [.workflowRun(id: 34000001234, repo: "example/project")], "global repo option; never copy log flag")
        check(specs("gh run view 42 —-repo example/project —json status") == [.workflowRun(id: 42, repo: "example/project")], "OCR dash normalization for CLI flags only")
        check(specs("gh run view: 42 --repo example/project") == [.workflowRun(id: 42, repo: "example/project")], "OCR verb punctuation")
        check(specs("gh run view 42 –repo example/project") == [.workflowRun(id: 42, repo: "example/project")], "OCR en dash flag")
        check(specs("gh pr view 42 -Rexample/project") == [.pullRequest(number: 42, repo: "example/project")], "attached repo option")
        check(specs("gh run view 42 --repo='example/project'") == [.workflowRun(id: 42, repo: "example/project")], "quoted repo")
        check(specs("Release-PR #191 (1.8.0) markus-barta/nuncid") == [.pullRequest(number: 191, repo: "markus-barta/nuncid")], "release PR versus release version")
        check(specs("PR42 markus-barta/nuncid") == [.pullRequest(number: 42, repo: "markus-barta/nuncid")], "attached PR and configured repo")
        check(specs("PR: 42 markus-barta/nuncid") == [.pullRequest(number: 42, repo: "markus-barta/nuncid")], "PR colon not a JSON field")
        check(specs("pull request #42 NUNCID") == [.pullRequest(number: 42, repo: "markus-barta/nuncid")], "PR label and explicit project scope")
        check(specs("NUNCID issue 42") == [.issue(tracker: .ppm, key: "NUNCID-42")], "issue label")
        check(specs("NUNCID 42") == [.issue(tracker: .ppm, key: "NUNCID-42")], "attached project/number")
        check(specs("🙂 PR42 markus-barta/nuncid") == [.pullRequest(number: 42, repo: "markus-barta/nuncid")], "UTF16 offsets")
        for text in ["#42", "PR42", "gh run view 34000001234", "gh run view 42 --repo ../secret", "gh run view 42 --repo example/a --repo example/b"] {
            let result = classify(text).filter(\.isVisibleCandidate)
            check(result.count == 1 && result[0].decision == .unresolved && result[0].spec == nil, "hold: \(text)")
        }
        check(specs("gh run view 42 --repo example/a; gh pr view 42 --repo example/b") == [.workflowRun(id: 42, repo: "example/a"), .pullRequest(number: 42, repo: "example/b")], "same literal, distinct command entities")
        check(specs("gh run view 42 --repo example/a\ngh run view 42 --repo example/b").count == 2, "newline command boundaries")
        check(classify("PR42 markus-barta/nuncid inspr-at/paimos").first?.decision == .unresolved, "conflicting repo context")
        check(specs("https://github.com.evil.example/example/project/actions/runs/42").isEmpty, "spoofed URL host")
        check(specs("https://evil.example/?next=https://github.com/example/project/pull/42").isEmpty, "nested URL does not authorize lookup")
        check(specs("https://evil.example/?next=https://pm.barta.cm/issues/NUNCID-70").isEmpty, "nested Paimos URL does not authorize lookup")
        check(specs("PR42 /tmp/markus-barta/nuncid").isEmpty, "filesystem path is not repository context")
        check(specs("PR42 /tmp/NUNCID").isEmpty, "project word in path is not repository context")
        check(specs("ticket 42 /tmp/NUNCID").isEmpty, "project word in path is not issue context")
        for value in ["../repo", "owner/../repo", "--bad/repo", "owner/repo;touch", "host/owner/repo", "owner/repo\n"] {
            check(CandidatePlanner.validatedGitHubRepo(value) == nil, "invalid repository: \(value)")
        }
        let clippedRepo = OCRContextFragment(text: "gh run view 42 --repo example/proj", lineIndex: 0, order: 0, endClipped: true)
        check(ScreenReferenceClassifier.classify(.init(fragments: [clippedRepo])).compactMap(\.spec).isEmpty, "syntactically valid truncated repository is not dispatched")
        let clippedPR = OCRContextFragment(text: "markus-barta/nuncid PR123", lineIndex: 0, order: 0, endClipped: true)
        check(ScreenReferenceClassifier.classify(.init(fragments: [clippedPR])).compactMap(\.spec).isEmpty, "truncated PR number is not dispatched")
        let clippedKey = OCRContextFragment(text: "NUNCID-70", lineIndex: 0, order: 0, startClipped: true)
        check(ScreenReferenceClassifier.classify(.init(fragments: [clippedKey])).compactMap(\.spec).isEmpty, "clipped prefix is not trusted")
        let completeScope = OCRContextFragment(text: "gh run view 42 --repo example/project --json stat", lineIndex: 0, order: 0, endClipped: true)
        check(ScreenReferenceClassifier.classify(.init(fragments: [completeScope])).compactMap(\.spec) == [.workflowRun(id: 42, repo: "example/project")], "complete scope survives unrelated trailing clipping")
        let dense = (1...50).map { "NUNCID-\($0)" }.joined(separator: " ")
        check(specs(dense).count == 50, "no legacy twelve-token cap in screen classification")
        check(classify(String(repeating: "NUNCID-1 ", count: 1000)).isEmpty, "oversized fragment fail closed")
        let metrics = Array(repeating: (0..<20).map { "\($0)%" }.joined(separator: " "), count: 40) + ["NUNCID-70"]
        check(ScreenReferenceClassifier.classify(.init(lines: metrics)).compactMap(\.spec) == [.issue(tracker: .ppm, key: "NUNCID-70")], "noise cannot starve later reference budget")

        func fragment(_ text: String, _ index: Int, _ x: Double, _ y: Double, _ width: Double, group: Int? = 1) -> OCRContextFragment {
            OCRContextFragment(text: text, lineIndex: index, order: index, confidence: 0.99,
                               region: OCRNormalizedRegion(x: x, y: y, width: width, height: 0.04), contextGroup: group)
        }
        let target = fragment("PR42", 0, 0.1, 0.6, 0.1)
        let near = fragment("--repo example/project", 1, 0.1, 0.66, 0.3)
        let far = fragment("--repo example/project", 1, 0.7, 0.66, 0.25)
        check(ScreenReferenceClassifier.classify(.init(fragments: [target, near])).compactMap(\.spec) == [.pullRequest(number: 42, repo: "example/project")], "same-block adjacent scope")
        check(ScreenReferenceClassifier.classify(.init(fragments: [target, far])).compactMap(\.spec).isEmpty, "no context across gutter")
        let otherWindow = fragment("--repo example/project", 1, 0.1, 0.66, 0.3, group: 2)
        check(ScreenReferenceClassifier.classify(.init(fragments: [target, otherWindow])).compactMap(\.spec).isEmpty, "no context across windows")
        let split = [fragment("PR", 0, 0.1, 0.6, 0.025), fragment("42", 1, 0.13, 0.6, 0.025), fragment("--repo example/project", 2, 0.16, 0.6, 0.3)]
        let joined = ScreenReferenceClassifier.classify(.init(fragments: split)).filter { $0.spec != nil }
        check(joined.count == 1 && joined[0].token.fragmentIndex == 1 && joined[0].token.characterOffset == 0, "split visual line preserves anchor")
        let wrapped = [fragment("gh run view", 0, 0.1, 0.66, 0.16), fragment("34000001234 --repo example/project", 1, 0.1, 0.6, 0.45)]
        check(ScreenReferenceClassifier.classify(.init(fragments: wrapped)).compactMap(\.spec) == [.workflowRun(id: 34000001234, repo: "example/project")], "wrapped command")
        check(ScreenReferenceClassifier.classify(.init(fragments: [near, target])).compactMap(\.spec) == ScreenReferenceClassifier.classify(.init(fragments: [target, near])).compactMap(\.spec), "geometry independent of OCR array order")
        let windows = [ScreenContextWindow(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)), ScreenContextWindow(id: 2, bounds: CGRect(x: 0, y: 0, width: 200, height: 200))]
        check(ScreenContextGeometry.owner(of: CGRect(x: 10, y: 10, width: 20, height: 10), windows: windows) == 1, "topmost context owner")
        check(ScreenContextGeometry.owner(of: CGRect(x: 90, y: 10, width: 30, height: 10), windows: windows) == nil, "reject line crossing occlusion")
        check(!ScreenContextGeometry.isCompleteIdentifier(CGRect(x: 0, y: 20, width: 20, height: 10), in: CGRect(x: 0, y: 0, width: 100, height: 100)), "crop-edge token rejected")

        let payload = #"{"databaseId":42,"workflowName":"CI","displayTitle":"Build main","status":"completed","conclusion":"success","headBranch":"main","headSha":"abcdef1234567890","createdAt":"2026-09-07T10:00:00Z","startedAt":"2026-09-07T10:00:02Z","updatedAt":"2026-09-07T10:02:05Z","url":"https://github.com/example/project/actions/runs/42","event":"push"}"#
        let line = GitHubRunPreview.line(data: Data(payload.utf8), id: 42, repo: "example/project")
        check(line?.key == "Run 42" && line?.state == "success" && line?.title == "Build main" && line?.detail.contains("Duration 2m 3s") == true, "run summary fields/duration")
        check(line?.id == CandidateSpec.workflowRun(id: 42, repo: "example/project").cacheKey, "run identity includes repo/type")
        check(line?.id != CandidateSpec.pullRequest(number: 42, repo: "example/project").cacheKey, "run/PR cache isolation")
        check(GitHubRunPreview.line(data: Data(payload.utf8), id: 43, repo: "example/project") == nil, "run response ID mismatch")
        check(GitHubRunPreview.line(data: Data(payload.utf8), id: 42, repo: "example/other") == nil, "run response repository mismatch")
        let args = GitHubRunPreview.arguments(id: 42, repo: "example/project")!
        check(args.prefix(5) == ["run", "view", "42", "--repo", "example/project"] && !args.contains("--log") && !args.last!.contains("jobs"), "fixed summary-only read arguments")
        check(GitHubRunPreview.arguments(id: 42, repo: "evil/repo; rm") == nil, "no shell/unsafe repo arguments")
        check(GitHubRunPreview.cacheLifetime(for: .workflowRun(id: 42, repo: "example/project"), line: line) == 300, "completed run cache TTL")
        let running = TicketLine(key: "Run 42", state: "in-progress", title: "CI", source: "gh")
        check(GitHubRunPreview.cacheLifetime(for: .workflowRun(id: 42, repo: "example/project"), line: running) == 30, "active run freshness")
        return failures
    }
}
