# claude-fix

Shared implementation of the claude-fix pipeline: comment `/fix` on a GitHub
issue and it gets picked up on the Mac Mini, fixed by Claude Code, verified,
pushed to `main`, and shipped to TestFlight. Comment `/fixall` on any issue
and it queues a `/fix` on every open issue in that repo instead (see
"Fixing every open issue" below). `.github/workflows/claude-fix.yml` here is
a **reusable workflow** — every repo that wants this capability adds a small
caller workflow (see `templates/caller-workflow.yml`) instead of duplicating
the logic.

Runs on `mac-mini-runner`, a single org-level self-hosted runner shared by
every repo in `PeteHHHH` — see the `commute`/`catch-my-train` repo's
`scripts/setup-runner.sh` for how that's registered; it only needs doing once
for the whole org, not per repo.

This repo is private, and GitHub blocks other repos from calling a private
repo's reusable workflows by default (`access_level: none` — every caller run
fails instantly with zero jobs created, "likely failed because of a workflow
file issue"). One-time fix, already done as of 2026-09-27:
`gh api repos/PeteHHHH/claude-fix/actions/permissions/access -X PUT -f access_level=organization`.

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

## Fixing every open issue

Comment `/fixall` on any issue in a claude-fix caller repo and the `fixall`
job lists every open issue in that repo and posts a plain `/fix` comment on
each one — it doesn't resolve anything itself. Each of those then runs
through the normal `fix` job exactly like a manually-typed `/fix`, complete
with its own status comments, retries, and TestFlight upload. Since there's
only one self-hosted runner, they queue and run one at a time rather than
all starting at once — no extra sequencing needed.

The `/fix` comments it posts must come from `petehhhhh`, since that's what
every caller workflow's own gating requires — a comment authored by
`github-actions[bot]` (this workflow's own default identity via
`github.token`) would be silently ignored. The `fixall` job works around
this by deliberately not setting `GH_TOKEN` in its own step, so `gh` falls
back to the Mac Mini's own logged-in `gh auth` session (`petehhhhh`)
instead - the same keychain-backed login Claude Code itself relies on (see
"Safety notes" below).

## Version numbers

Every real ship - both `/fix`'s own automatic TestFlight upload and a manual
`scripts/ship.sh` run - bumps `MARKETING_VERSION` as well as
`CURRENT_PROJECT_VERSION`, via the shared `scripts/bump_build_number.py`.
The visible version always moves forward (e.g. 2.01 → 2.02) instead of
sitting frozen while only the internal build number climbs in parentheses.
A ship whose diff is large (≥1000 changed lines) gets a major bump instead
(e.g. 2.9 → 3.0) - both `/fix` and `ship.sh` compute this the same way, from
the diff since the start of the run (`/fix`) or since the last release
commit (`ship.sh`).

## Shipping interactively ("ship this to TestFlight")

`scripts/ship.sh` here, plus the personal `ship` skill at
`~/.claude/skills/ship/SKILL.md` that triggers on "ship this"/"ship to
TestFlight" in any claude-fix caller repo, is for a real, user-requested
release outside the `/fix` flow. It's the one script/skill every repo
uses - no per-repo copy to drift out of sync - and it signs exactly the way
`/fix` does: automatic signing + an App Store Connect API key
(`export_and_upload.sh`, same as below), never a manually-created Apple
Distribution cert or provisioning profile.

One-time setup, shared by every repo (same Apple Developer account/team):

- Create `~/.appstoreconnect/ship_env` on the machine you ship from:
  ```
  export ASC_KEY_ID=<key id>
  export ASC_ISSUER_ID=<issuer id>
  ```
  Reuse the `ASC_KEY_ID`/`ASC_ISSUER_ID` already configured as this repo's
  secrets (same values, since it's one shared key across apps) — the
  Issuer ID isn't retrievable via the GitHub API once it's a secret, so
  copy it from App Store Connect → Users and Access → Integrations →
  App Store Connect API (or wherever you saved it when the key was made).
  The matching `AuthKey_<ASC_KEY_ID>.p8` must already be at
  `~/.appstoreconnect/private_keys/` (same file `export_and_upload.sh`
  uses for `/fix`).

To ship: from any caller repo's root, say "ship this" (or run
`.claude-fix-tools/scripts/ship.sh` directly - clone/pull this repo to
`.claude-fix-tools/` first if it isn't already sitting there from a prior
`/fix` run). It fetches/merges `origin/main`, does a Release smoke build,
bumps `MARKETING_VERSION` (auto-incrementing - minor by default, major if a
lot has changed since the last release, or pass an explicit version as
`$1`) and `CURRENT_PROJECT_VERSION` together, commits + pushes to `main`,
then archives/exports/uploads via `export_and_upload.sh` - the exact same
script and signing path `/fix` uses for its own upload step.

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
  every `gh issue comment` and `git push` fails with a 403. This has to be
  declared in **both** the caller's job and the reusable workflow's own job —
  a calling job's permissions are a hard ceiling on what it invokes, so
  omitting it from the caller rejects the whole run at dispatch time
  (`startup_failure`, zero jobs created, "nested job 'fix' is requesting
  ..., but is only allowed ..."). `templates/caller-workflow.yml` already
  includes it.
- If the code fix fails to build, the workflow stops there — no push, no
  TestFlight upload, no false "shipped" claim. If the fix lands but the
  TestFlight upload fails, you're told which one happened.
- TestFlight upload (when enabled) is fully automatic once the build
  succeeds — there is no manual approval gate before it reaches external
  testers on that app.
- Retries aren't blind: the prompt tells Claude to run
  `gh issue view $ISSUE_NUMBER --comments` itself before doing anything else,
  so it reads the full thread — any discussion, plus this workflow's own
  status comments from prior attempts (working-on-it, shipped, landed but
  didn't ship, failed, no-change-needed). Commenting `/fix` again after a
  failed attempt gives Claude what the last attempt tried and why it didn't
  land, instead of starting over cold. The workflow doesn't fetch or inject
  any of that itself — it's cheap for Claude to pull with a tool call it
  already has (`gh issue *` is in `--allowedTools`), so there's no reason to
  duplicate it in the prompt.
- The issue only gets closed once the fix has actually shipped — the
  workflow closes it itself after the build-number bump and (if enabled)
  the TestFlight upload succeed, not the moment Claude's commit lands.
  Claude is told not to use a GitHub closing keyword (`Closes #N`, etc.) in
  its commit message for this reason — that would close the issue
  immediately on push, even if a later step then fails. If a closing
  keyword slips through anyway and a later step fails, the workflow
  reopens the issue as part of reporting that failure, so a failed run
  never leaves an issue closed.
- A retry doesn't skip the steps that failed last time just because Claude
  finds nothing left to fix in the code. If issue #12's code fix already
  landed on main but the TestFlight upload failed, a `/fix` retry has
  Claude correctly make no new commit — but the workflow still knows (from
  Claude's fix commit and/or the build-number-bump commit already carrying
  "issue #12" in their message) that this issue's fix isn't shipped yet, so
  it reuses the already-bumped build number and retries the upload instead
  of posting "nothing needed shipping" and stopping.
