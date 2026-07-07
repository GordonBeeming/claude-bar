<p align="center">
  <img src="docs/icon.png" width="128" alt="ClaudeBar icon" />
</p>

<h1 align="center">ClaudeBar</h1>

<p align="center">
  Your Claude usage limits, in the macOS menu bar, in your timezone.
</p>

<p align="center">
  <a href="https://github.com/GordonBeeming/claude-bar/actions/workflows/build.yml"><img src="https://github.com/GordonBeeming/claude-bar/actions/workflows/build.yml/badge.svg" alt="Build status" /></a>
  <a href="https://github.com/GordonBeeming/claude-bar/releases/latest"><img src="https://img.shields.io/github/v/release/GordonBeeming/claude-bar" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)-blue" alt="macOS 15+ Apple Silicon" />
</p>

---

I got tired of opening a terminal (or getting cut off mid-session) to find out how much Claude I had left. ClaudeBar sits in the menu bar and shows the number that matters: the highest usage percentage across all your limits. The dropdown breaks down every category — session (5h window), weekly across all models, and any model-scoped limits like Fable or Sonnet.

Two things it gets right that pushed me to build it:

- **Reset times are in *your* timezone.** "Resets 4:20 pm today", not a UTC guess that's off by half a day.
- **Zero lag.** The menu renders instantly from cached data and refreshes in the background. No frozen beachball while a network call decides your fate.

## Install

```sh
brew install --cask gordonbeeming/tap/claude-bar
```

Needs macOS 15+ on Apple Silicon, plus [Claude Code](https://claude.com/claude-code) installed and logged in — ClaudeBar reads its OAuth token from the Keychain (read-only, one permission prompt, click **Always Allow**). It never writes or refreshes the token; that's Claude Code's job. If the token expires, ClaudeBar keeps showing the last known numbers with a hint to open Claude Code.

### From source

```sh
make install
open ~/Applications/ClaudeBar.app
```

`make install` signs with your Apple Development identity when one exists, falling back to ad-hoc. Ad-hoc mints a fresh signing identity every build, so the Keychain prompt comes back after each rebuild; a real identity keeps the grant forever.

## Settings

Open **Settings…** from the dropdown:

- **Usage colours** — by default the icon turns orange/red when Claude's API says a limit is at warning/critical. Untick *Use Claude's severity levels* and you get a blue → orange → red bar: drag the two splitters to pick your own warning and critical percentages.
- **Launch at login** — on by default, toggle it here.

## How it works

ClaudeBar polls `GET https://api.anthropic.com/api/oauth/usage` (once a minute, plus on menu open when stale) with the Claude Code OAuth token, and renders the `limits` array it gets back — one row per limit with percent used, a progress bar, and "Resets 5:00 pm · in 4h 55m" converted from UTC to your system timezone. The app is an accessory (no Dock icon, no app switcher entry); it just lives in the menu bar.

## Dev loop

```sh
make run    # swift run, straight from source
make test   # swift test — core logic is fully unit-tested
```

The core library (`ClaudeBarCore`) holds everything testable: ISO8601 parsing, timezone formatting, severity thresholds, JSON decoding that survives unknown limit kinds. The app target is a thin SwiftUI `MenuBarExtra` on top.

## Releasing

Tag `vX.Y`, publish a GitHub release for it, and CI does the rest: signs with Developer ID, notarizes, staples, uploads the DMG, and pushes the updated cask to [the tap](https://github.com/GordonBeeming/homebrew-tap) so `brew upgrade --cask claude-bar` picks it up.
