
## 2026-08-26 — concurrent agents share one index
- When subagents commit concurrently on the same branch, never run a bare `git commit` in the controller; a subagent's staged change gets swept into the controller's commit (happened: UPCItemDBService.swift deletion landed in the phase-5 plan commit fc7f037). Always commit with an explicit pathspec: `git commit -m "…" -- <paths>`.
- Make subagents stage by path too (`git add <file>`), never `git add -A`.
- Reviewer subagents must be told explicitly "never `git stash`, `checkout`, or `reset`" — one stashed the worktree mid-review while another implementer had uncommitted work.
- Implementer reports sometimes paraphrase/estimate test counts. Dispatch prompts must say "paste the literal command output; never estimate", and reviewers should spot-check one count against the file.
- Implementers must commit with a pathspec too (`git commit -m "…" -- <files>`), not just stage by path — a bare `git commit` after `git add <paths>` still sweeps other agents' staged changes. Put this in every dispatch prompt.
- Implementers must never `git stash` either (one did, to isolate a failure, while another agent had uncommitted work).

## 2026-08-26 — simulator crash during a subagent test run
- The user surfaced a SIGABRT crash report from the simulator: a new XCTest force-cast a JSON request body (`as! [String: String]`) whose values were arrays/objects → `swift_dynamicCastFailure` aborts the whole test process, so the run ends with **no** `Executed … tests` line.
- Rule: briefs and dispatches say "never `as!` on decoded JSON in tests — `as? [String: Any]` and assert per key"; a report without a literal `Executed … tests` / `** TEST SUCCEEDED **` pair is a failed run, and the newest `~/Library/Logs/DiagnosticReports/Shrunk-*.ips` names the test (frame list of the faulting thread).
