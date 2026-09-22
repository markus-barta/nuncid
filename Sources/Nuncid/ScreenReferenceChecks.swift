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

        func pulls(_ input: OCRContextInput) -> [CandidateSpec] {
            ScreenReferenceClassifier.classify(input).compactMap(\.spec).filter {
                if case .pullRequest = $0 { return true }
                return false
            }
        }
        let transcript = OCRContextInput(fragments: [
            fragment("https://github.com/markus-barta/nixcfg/pull/722", 0, 0.1, 0.90, 0.7),
            fragment("Completed PAI-1056 and tidyrepo | paimos", 1, 0.1, 0.62, 0.6),
            fragment("gh pr merge 722 --squash --auto", 2, 0.1, 0.48, 0.6),
            fragment("gh pr checks 722 --json name,state", 3, 0.1, 0.40, 0.6),
            fragment("Deployment PR #722 is running its protected checks", 4, 0.1, 0.58, 0.75),
            fragment("gh pr diff 722", 5, 0.1, 0.30, 0.4),
            fragment("gh pr view 722 --json state", 6, 0.1, 0.20, 0.5),
            fragment("PR #99", 7, 0.1, 0.05, 0.2),
        ])
        let transcriptResult = ScreenReferenceClassifier.classify(transcript)
        let transcriptPulls = transcriptResult.compactMap(\.spec).filter { if case .pullRequest = $0 { return true }; return false }
        check(transcriptPulls.count == 6 && Set(transcriptPulls) == [.pullRequest(number: 722, repo: "markus-barta/nixcfg")], "unique pull URL scopes every mention of that pull request")
        check(transcriptResult.contains { if case .issue(_, "PAI-1056") = $0.spec { return true }; return false }, "nearby project key stays its own issue")
        check(transcriptResult.contains { $0.token.raw == "99" && $0.spec == nil && $0.decision == .unresolved }, "a different pull number does not borrow the URL")
        let observed = [
            "Complete PAI-1050 and tidyrepo | paimos",
            "✓ commented on NIX-570",
            "branch 'deploy/nix-570-pai-1050' set up to track 'origin/deploy/nix-570-pai-1050'.",
            "https://github.com/markus-barta/nixcfg/pull/722",
            "Ran gh pr merge 722 --squash --auto",
            "gh pr checks 722 --json name,state --jq 'group_by(.state)|map({state:.[0].state,count:length})'",
            #"[{"count":9,"state":"IN_PROGRESS"},{"count":1,"state":"NEUTRAL"},{"count":2,"state":"SUCCESS"}]"#,
            "Deployment PR #722 is running its protected checks with auto-merge enabled. The release and final pin review are complete.",
            "✓ updated NIX-570",
            "08:22:27 UTC",
            "Ran gh pr checks 722 --json name,state --jq 'group_by(.state)|map({state:.[0].state,count:length})'",
            "gh pr view 722 --json state,mergeStateStatus,mergeCommit,headRefOid",
            #"{"headRefOid":"6a61506850ac02510f09dc872a91b5b5fcc23cc2","mergeCommit":null,"mergeStateStatus":"BLOCKED","state":"OPEN"}"#,
            "Twelve deployment checks passed; one remains."
        ]
        let observedInput = OCRContextInput(fragments: observed.enumerated().map { index, line in
            fragment(line, index, 0.08, 0.92 - Double(index) * 0.05, 0.84)
        })
        let observedResult = ScreenReferenceClassifier.classify(observedInput)
        let observedPulls = observedResult.compactMap(\.spec).filter { if case .pullRequest = $0 { return true }; return false }
        check(observedPulls.count == 6 && Set(observedPulls) == [.pullRequest(number: 722, repo: "markus-barta/nixcfg")], "observed nixcfg transcript resolves every pull-request mention")
        check(observedResult.contains { if case .issue(_, "PAI-1050") = $0.spec { return true }; return false }, "window title keeps PAI-1050 as its own issue")
        check(!observedResult.contains { if case .pullRequest(_, "inspr-at/paimos") = $0.spec { return true }; return false }, "paimos in the window title does not claim the pull request")
        let replaced = OCRContextInput(fragments: [
            fragment("pull request #42 NUNCID", 0, 0.1, 0.20, 0.5),
            fragment("https://github.com/markus-barta/nixcfg/pull/42", 1, 0.1, 0.80, 0.7),
        ])
        check(Set(pulls(replaced)) == [.pullRequest(number: 42, repo: "markus-barta/nixcfg")], "explicit pull URL replaces a nearby project key")
        let keptSlug = OCRContextInput(fragments: [
            fragment("PR42 markus-barta/nuncid", 0, 0.1, 0.20, 0.5),
            fragment("https://github.com/example/other/pull/42", 1, 0.1, 0.80, 0.6),
        ])
        check(Set(pulls(keptSlug)) == [.pullRequest(number: 42, repo: "markus-barta/nuncid"), .pullRequest(number: 42, repo: "example/other")], "same-line repository slug keeps its own scope")
        let conflict = OCRContextInput(fragments: [
            fragment("https://github.com/markus-barta/nixcfg/pull/722", 0, 0.1, 0.80, 0.7),
            fragment("https://github.com/inspr-at/paimos/pull/722", 1, 0.1, 0.40, 0.7),
            fragment("PR #722", 2, 0.1, 0.10, 0.2),
        ])
        let conflicted = ScreenReferenceClassifier.classify(conflict)
        check(Set(conflicted.compactMap(\.spec).filter { if case .pullRequest = $0 { return true }; return false }) == [.pullRequest(number: 722, repo: "markus-barta/nixcfg"), .pullRequest(number: 722, repo: "inspr-at/paimos")], "distinct pull URLs stay distinct")
        check(conflicted.filter { $0.spec == nil && $0.decision == .unresolved && $0.reason == "Conflicting or invalid scope" }.count == 1, "unscoped mention does not choose between two URLs")
        let separateWindow = OCRContextInput(fragments: [
            fragment("https://github.com/markus-barta/nixcfg/pull/722", 0, 0.1, 0.80, 0.7, group: 1),
            fragment("gh pr view 722", 1, 0.1, 0.20, 0.4, group: 2),
        ])
        check(pulls(separateWindow) == [.pullRequest(number: 722, repo: "markus-barta/nixcfg")], "pull URL does not cross windows")
        check(ScreenReferenceClassifier.classify(separateWindow).contains { $0.contextGroup == 2 && $0.spec == nil }, "the other window still needs a repository")
        let runs = OCRContextInput(fragments: [
            fragment("https://github.com/example/project/actions/runs/42", 0, 0.1, 0.80, 0.7),
            fragment("gh run view 42", 1, 0.1, 0.20, 0.4),
            fragment("gh pr view 42", 2, 0.1, 0.10, 0.4),
        ])
        let runResult = ScreenReferenceClassifier.classify(runs)
        check(runResult.compactMap(\.spec) == [.workflowRun(id: 42, repo: "example/project"), .workflowRun(id: 42, repo: "example/project")], "unique run URL scopes a later gh run view")
        check(runResult.contains { $0.category == .pullRequest && $0.spec == nil }, "a run URL does not scope a pull request")
        let wrappedChecks = OCRContextInput(fragments: [
            fragment("gh pr checks", 0, 0.1, 0.66, 0.2),
            fragment("722", 1, 0.1, 0.60, 0.08),
            fragment("https://github.com/markus-barta/nixcfg/pull/722", 2, 0.1, 0.90, 0.7),
        ])
        check(Set(pulls(wrappedChecks)) == [.pullRequest(number: 722, repo: "markus-barta/nixcfg")], "wrapped gh pr checks inherits the window URL")
        for text in ["gh pr checks 722", "gh pr diff 722", "gh pr merge 722 --squash --auto"] {
            let found = classify(text).filter(\.isVisibleCandidate)
            check(found.count == 1 && found[0].spec == nil && found[0].decision == .unresolved, "hold without a repository: \(text)")
        }
        let anchor = CGRect(x: 100, y: 400, width: 40, height: 16)
        let content = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let owner = CGRect(x: 40, y: 80, width: 900, height: 1_000)
        check(ExplorationPolicy.contextRead(around: anchor, category: .pullRequest, owner: owner, content: content) == owner.intersection(content), "pull context reads the whole owning window")
        let tall = CGRect(x: 0, y: 0, width: 800, height: 2_400)
        let band = ExplorationPolicy.contextRead(around: anchor, category: .workflowRun, owner: tall, content: tall)
        check(tall.contains(band) && band.contains(anchor) && band.height <= 1_600 && band.height > 1_000, "tall window context stays bounded around the mention")
        let crop = ExplorationPolicy.contextRead(around: anchor, category: .issue, owner: owner, content: content)
        let narrow = CGRect(x: anchor.midX - 500, y: anchor.midY - 120, width: 1_000, height: 240).intersection(content)
        check(crop == narrow && crop.contains(CGPoint(x: anchor.midX, y: anchor.midY)) && crop.height <= 240 && crop.width <= 1_000, "issue context stays a narrow crop")
        return failures
    }
}
