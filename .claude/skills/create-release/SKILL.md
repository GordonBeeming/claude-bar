---
name: create-release
description: Create a new release for ClaudeBar. Use when the user says "create a release", "new release", "cut a release", "ship it", or wants to bump/publish a ClaudeBar version.
---

# Create Release

Create a new GitHub release for ClaudeBar. Publishing the release triggers the CI pipeline that signs, notarizes, and ships the DMG plus the Homebrew cask.

## Steps

1. Pull latest: `but pull`
2. Confirm nothing is unmerged — this should be empty:
   ```bash
   gh pr list --repo gordonbeeming/claude-bar --state open
   ```
3. Determine the next version by checking existing releases:
   ```bash
   gh release list --repo gordonbeeming/claude-bar --limit 5
   ```
4. Bump the minor version (e.g. v0.2 → v0.3). Never use a patch number in the tag.
5. Create the release:

````bash
gh release create v{major}.{minor} \
  --repo gordonbeeming/claude-bar \
  --target main \
  --title "ClaudeBar v{major}.{minor} — {short description}" \
  --notes "$(cat <<'EOF'
# ClaudeBar v{major}.{minor} — {short description}

## What's New

- {list changes since last release using git log}

## Install

```bash
brew upgrade --cask gordonbeeming/tap/claude-bar
```

Or download the DMG from the assets below.
EOF
)"
````

Publish it (no `--draft`) — the pipeline runs on `release: published`.
6. The release pipeline (`.github/workflows/build.yml`) automatically:
   - Build + test
   - Sign with Developer ID
   - Notarize + staple with Apple
   - Create + sign the DMG
   - Upload the DMG asset to the release
   - Update the Homebrew tap cask (`GordonBeeming/homebrew-tap/Casks/claude-bar.rb`)
7. Watch it finish, then report the release URL + run: `gh run watch --repo gordonbeeming/claude-bar`

## Version Format

- Tags: `v{major}.{minor}` (e.g. `v0.3`) — NO patch number; the workflow guard rejects any tag whose (optionally `v`-prefixed) remainder isn't `major.minor`.
- CI sets `CFBundleShortVersionString` to `{major}.{minor}` and `CFBundleVersion` to the run number separately — they're not combined into a single dotted bundle version.
- The tag `v0.3` with run number 45 sets `CFBundleShortVersionString=0.3` and `CFBundleVersion=45`.

## Generating Release Notes

```bash
LAST_TAG=$(gh release list --repo gordonbeeming/claude-bar --limit 1 --json tagName --jq '.[0].tagName')
git fetch origin main
git log ${LAST_TAG}..origin/main --oneline
```

Run any hand-written notes through the `humanizer:humanizer` skill (Skill tool) before publishing — it strips AI-writing patterns from release-note prose.

## Important

- Never reuse or delete existing release tags.
- Always bump the minor version; never use a `.0` patch in tags (v0.3, not v0.3.0).
- Don't use `--draft` — a draft doesn't fire `release: published`, so CI won't build.
- The release triggers the full CI pipeline (notarization takes a few minutes) — wait for it to go green before telling anyone to `brew upgrade`.
- The release event re-runs `build-and-test` (it's not skipped just because the branch already built on every push), and the signing job only starts once that passes — check both jobs' logs with `gh run view --log-failed --repo gordonbeeming/claude-bar`. A failure in signing specifically usually means an expired notarization app-password / Developer ID cert in the `prod` environment, or a bad tag.
