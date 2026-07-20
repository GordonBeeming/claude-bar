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
   ```bash
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
   ```
   Publish it (no `--draft`) — the pipeline runs on `release: published`.
6. The release pipeline (`.github/workflows/build.yml`) automatically:
   - Build + test
   - Sign with Developer ID
   - Notarize + staple with Apple
   - Create + sign the DMG
   - Upload the DMG asset to the release
   - Update the Homebrew tap cask (`GordonBeeming/homebrew-tap/Casks/claude-bar.rb`)
7. Watch it finish, then report the release URL + run: `gh run watch`

## Version Format

- Tags: `v{major}.{minor}` (e.g. `v0.3`) — NO patch number; the workflow guard rejects anything else.
- Bundle version: `{major}.{minor}.{runNumber}` — CI adds the run number as the patch component.
- The tag `v0.3` with run number 45 produces bundle version `0.3.45`.

## Generating Release Notes

```bash
LAST_TAG=$(gh release list --repo gordonbeeming/claude-bar --limit 1 --json tagName --jq '.[0].tagName')
git log ${LAST_TAG}..HEAD --oneline
```

Run any hand-written notes through the humanizer pass before publishing.

## Important

- Never reuse or delete existing release tags.
- Always bump the minor version; never use a `.0` patch in tags (v0.3, not v0.3.0).
- Don't use `--draft` — a draft doesn't fire `release: published`, so CI won't build.
- The release triggers the full CI pipeline (notarization takes a few minutes) — wait for it to go green before telling anyone to `brew upgrade`.
- A red release job is almost always the sign/notarize/upload stage, not a compile error (the build job already ran on every push). Check `gh run view --log-failed`; usual causes are an expired notarization app-password / Developer ID cert in the `prod` environment, or a bad tag.
