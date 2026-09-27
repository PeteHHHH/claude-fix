# claude-fix

Shared implementation of the claude-fix pipeline: comment `/fix` on a GitHub
issue and it gets picked up on the Mac Mini, fixed by Claude Code, verified,
pushed to `main`, and shipped to TestFlight. `.github/workflows/claude-fix.yml`
here is a **reusable workflow** — every repo that wants this capability adds a
small caller workflow (see `templates/caller-workflow.yml`) instead of
duplicating the logic.

Runs on `mac-mini-runner`, a single org-level self-hosted runner shared by
every repo in `PeteHHHH` — see the `commute`/`catch-my-train` repo's
`scripts/setup-runner.sh` for how that's registered; it only needs doing once
for the whole org, not per repo.

## Adding claude-fix to a repo

1. Copy `templates/caller-workflow.yml` to that repo's `.github/workflows/claude-fix.yml`
   and fill in `scheme`, `bundle_id`, `team_id`, `xcodeproj_path` for that project.
2. Give it an App Store Connect API key for the TestFlight upload:
   - Reuse the existing key already on the Mac Mini (`~/.appstoreconnect/private_keys/`)
     if it has App Manager access to this app too, or generate a new one in
     App Store Connect → Users and Access → Integrations → App Store Connect API.
   - Add `ASC_KEY_ID` and `ASC_ISSUER_ID` as secrets — either on that repo directly,
     or once as **org-level secrets** (org Settings → Secrets and variables →
     Actions → New organization secret) scoped to whichever repos need them, so
     you're not re-adding the same key everywhere.
3. Optionally add `NTFY_TOPIC` the same way for phone push notifications.
4. Test with a throwaway issue and a `/fix` comment before trusting it with something real.

To land fixes on `main` without ever touching TestFlight (e.g. while still
testing a new repo), set `enable_testflight: false` in that repo's caller
workflow.

## Safety notes

- Only comments from `petehhhhh` trigger a run — the gating `if:` lives in
  each repo's own caller workflow, not here, since a reusable workflow can't
  see the triggering event until the caller has already decided to invoke it.
- Claude runs with an explicit `--allowedTools` list (file edits, plus `git`,
  `xcodebuild`, and `python3`/`xcrun`/`cp`/`ls`/etc. via Bash) rather than a
  blanket permission bypass — there's no one present to approve prompts, so
  anything outside that list is auto-denied instead of hanging or crashing
  the run. This Mac's Claude Code install also actively blocks
  `--permission-mode bypassPermissions`/`--dangerously-skip-permissions` for
  unattended runs outright (fails instantly with no output).
- The runner's `launchd` service must NOT have `SessionCreate` set in its
  plist — that creates an isolated security session with no access to the
  login keychain, and Claude Code's OAuth credentials live in the login
  keychain. With it set, every run fails with "Not logged in".
- The job requests `contents: write` and `issues: write` explicitly, since
  this org caps the default `GITHUB_TOKEN` at read-only — without this,
  every `gh issue comment` and `git push` fails with a 403.
- If the code fix fails to build, the workflow stops there — no push, no
  TestFlight upload, no false "shipped" claim. If the fix lands but the
  TestFlight upload fails, you're told which one happened.
- TestFlight upload (when enabled) is fully automatic once the build
  succeeds — there is no manual approval gate before it reaches external
  testers on that app.
