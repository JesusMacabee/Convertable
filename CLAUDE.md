# Convertable

macOS menu bar app, LAN web dashboard and `convertctl` CLI that mirror a lossless library to AAC for Apple Music and an
iPod Classic. SwiftPM package (Swift 6 language mode). Design: `docs/DESIGN.md`. The README says Claude wrote the code;
keep that disclosure when editing it.

## Build and gate

- Always `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` before `swift build` or `swift test` (the
  Command Line Tools have no XCTest). `Scripts/test.sh` sets it for you.
- **The gate:** `Scripts/test.sh > /tmp/convertable-gate.log 2>&1; echo "exit=$?"`. It is the full suite with a stall
  watchdog (the watchdog arms only after the first test starts; a clean rebuild takes minutes). Report the exit code.
- **Other gate, when a change touches the dashboard's resources or the app bundle:** `Scripts/build-app.sh` (no
  `--install`). Debug builds fall back to `Bundle.module`, so tests cannot catch a broken resource lookup in the `.app`.
  Installing to `/Applications` and curling `/` on the installed app is the maintainer's step, not an agent's.
- Tests and agents never touch the real share, the real Music library or the user's settings; fixtures live in
  `Fixtures/` (gitignored) and the throwaway "Convertable Test" Music library.

## The lead

This session is the lead (from the Department of Internal Arguments `templates/lead.md`, adapted). It dispatches the
`doia:` role agents, reads their reports and decides. It does not write the code an agent was briefed for, and does not
review it in place of a reviewer. Pushing, approving and talking to the maintainer are the lead's alone.

Small edits, questions and exploration are done directly in this session; briefing an agent costs more than it saves.

### Before a dispatch

1. **An issue first.** Every dispatched task has a GitHub issue in `JesusMacabee/Convertable`. The brief carries a line of
   its own: `issue: JesusMacabee/Convertable#N`. The SAFO v0.1.2 guard does not check it yet (that rule is on SAFO's
   `main`, unreleased), so this is the lead's job until a release carries it.
2. **The brief** follows DoIA's `templates/brief.md`: outcome, scope and non-goals, acceptance criteria with observable
   examples, base commit, permitted files, the gate above, stop conditions, and the evidence the report must carry. A
   brief with no gate, model or base commit is not ready. Local model step: `local-llm: n/a - no local model`.
3. **The role** by what the work is:
   - Code from a prose description, and fix rounds: `doia:implementer`.
   - A plan whose code is already complete: `doia:transcriber` (cheap tier; never security-sensitive code).
   - Every finished task: `doia:reviewer`, never the author.
   - Also `doia:adversarial-reviewer`, after the reviewer and never instead of it, when the diff touches: dashboard auth
     (token cookie and Bearer, the `X-Convertable` header, bind address), anything that deletes, quarantines or
     supersedes files or Music entries, AppleScript built from data (`MusicBridge` quoting), output paths derived from
     tags or source folder names, or settings and database decoding.
4. **The model, explicitly**, as the Agent call's `model`: `sonnet` for the implementer and both reviewers, `haiku` for
   the transcriber. Never inherit. Opus only with the maintainer's OK and the reason, in their own words.
5. **Packs** by the domain the diff touches: `doia:pack-threat-model` for the risky areas above;
   `doia:pack-python-untrusted-input` for parsers, path confinement and hostile-input tests (it is written for Python;
   the path, symlink and parser points carry over); `doia:pack-gha-security-dast` if a GitHub Actions workflow is added.
6. **The round.** Round 1 has no prior findings; round N lists the reviewer findings it addresses by number.

### Reading a report

- Read the header first. `GATE` must show an exit code, `TREE` must be clean for a reviewer, `MODEL` must match the
  dispatch. If one is missing, re-dispatch with a note; do not fill it in from your own reading.
- `NOT VERIFIED` items are now the lead's: run them, dispatch them, or tell the maintainer they are open.
- Blocking findings go back to an implementer as the next round. Important findings go back unless the maintainer
  accepts them. Minor findings may ride the next round that touches the file.
- Any proposal to weaken a check is the maintainer's decision. Stop and ask.

### The loop

1. Implementer (or transcriber) round N.
2. Reviewer: full review in round 1, scoped re-review after.
3. Adversarial reviewer when the diff is in a risky area, briefed with the findings already resolved.
4. Findings remain: round N+1. After two failed rounds on the same finding class, stop and tell the maintainer.
5. Both reviewers approve (or the maintainer accepts what is left): push.

### Pushing

The maintainer's standing instruction (2026-10-17) is to push to `origin main` after committing. Under this workflow
it applies to dispatched work only once the loop above has closed. Agents never push, merge, tag or release, and a
brief cannot grant it. Approval is never inferred from silence, CI, a comment or an agent's verdict.
