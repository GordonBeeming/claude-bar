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

ClaudeBar shows your Claude plan's usage limits in the menu bar — the same numbers you'd find on Claude's usage page, nothing more. The bar shows the highest percentage across your limits; the dropdown lists each one: session (5h window), weekly across all models, and any model-scoped limits like Fable or Sonnet, each with a progress bar and its reset time in your local timezone.

That's the whole app. No cost tracking, no charts, no extras. The menu renders instantly from cached data and refreshes in the background.

> Looking for the same simple menu bar experience for Codex? See [CodexBar](https://github.com/GordonBeeming/codex-bar).

## Preview

<p align="center">
  <a href="docs/screenshot.png">
    <img src="docs/screenshot.png" width="720" alt="ClaudeBar menu showing usage limits" />
  </a>
</p>

## Install

```sh
brew install --cask gordonbeeming/tap/claude-bar
```

Needs macOS 15+ on Apple Silicon, plus [Claude Code](https://claude.com/claude-code) installed and logged in — ClaudeBar reads its OAuth token from the Keychain (read-only; click **Always Allow** when macOS asks). It never writes or refreshes the token; that's Claude Code's job. If the token expires, ClaudeBar keeps showing the last known numbers with a hint to open Claude Code. macOS re-asks for that Keychain permission every so often — [Keychain access](#keychain-access) explains why, and how self-contained sign-in stops it.

### From source

```sh
make install
open ~/Applications/ClaudeBar.app
```

`make install` signs with your Apple Development identity when one exists, falling back to ad-hoc. Ad-hoc mints a fresh signing identity every build, so the Keychain prompt comes back after each rebuild; a real identity keeps the grant forever.

## Settings

Open **Settings…** from the dropdown:

- **Usage colours** — by default the icon turns orange/red when Claude's API says a limit is at warning/critical. Untick *Use Claude's severity levels* and you get a blue → orange → red bar: drag the two splitters to pick your own warning and critical percentages.
- **⛽ Fuel tank mode** — flip every percentage and progress bar from *used* to *remaining*. Instead of a limit filling up from 0 → 100% as you burn through it, it starts full and drains toward empty, like a fuel gauge. It's purely cosmetic: colours, the 🔥 over-pace flame, and the steady-pace marker all still track real usage, so a nearly-empty tank still turns red.
- **Telemetry** — off by default. Turn it on to keep your own usage history on disk (see [Telemetry](#telemetry)).
- **Launch at login** — on by default, toggle it here.

## Telemetry

ClaudeBar can write your usage history to disk in OpenTelemetry's OTLP JSON format, so you can chart it with `jq` and a spreadsheet or feed it into any OpenTelemetry tool. It's opt-in. Nothing is written until you tick **Record usage history** in Settings, and ClaudeBar never uploads the files. The folder is yours, though: if it syncs (Documents does when iCloud Desktop & Documents is on), the files sync with it, so choose a local folder if you'd rather they stayed on this Mac.

By default the files go to `~/Documents/ClaudeBar Telemetry`. You can choose another folder in Settings, along with how often to record (every 1, 5, 15, 30 or 60 minutes, default 5) and how long to keep files (7, 30, 90, 180 or 365 days, or forever; default 90). Each day gets two files:

- `metrics-YYYY-MM-DD.jsonl` holds one OTLP `ExportMetricsServiceRequest` per line, one line per recording.
- `logs-YYYY-MM-DD.jsonl` holds one OTLP `ExportLogsServiceRequest` per line, written only when something changed.

Files older than the retention window are deleted. ClaudeBar only ever deletes files matching those two name patterns, so other files in the folder are left alone.

### Metrics

| Metric | Type | What it is |
|---|---|---|
| `claude.usage.limit.utilization` | gauge, % | Each limit in the menu (session, weekly, per-model weekly, spend). Attributes: `limit.kind`, `limit.name`, `limit.group`, `model.id`/`model.name` for model-scoped limits, `severity`, `is_active` |
| `claude.usage.limit.resets_at` | gauge, Unix seconds | When that limit's window ends |
| `claude.usage.limit.window_elapsed` | gauge, % | How far through its window the limit is. Utilization above this means you're burning faster than an even pace |
| `claude.extra_usage.enabled`, `.used_credits`, `.monthly_limit`, `.utilization` | gauge | Pay-as-you-go extra usage, as the API reports it (`currency`, `decimal_places` attributes) |
| `claude.code.tokens` | cumulative sum | Tokens per `model` and `token.type`: `input`, `output`, `cache_read`, `cache_write_5m`, `cache_write_1h` |
| `claude.code.messages` | cumulative sum | Model responses per `model` |
| `claude.code.server_tool_requests` | cumulative sum | Web search and web fetch calls per `model` and `tool` |
| `claude.guest_passes.available`, `.limit` | gauge | Claude Code guest passes you can still hand out, and how many you get in total |
| `claude.credit_grant.available`, `.amount` | gauge | 1 while a promotional extra-usage credit is waiting to be claimed, and its value in minor units (cents) |

Token counts come from Claude Code's transcripts in `~/.claude/projects`, because the usage API doesn't report tokens. That means they only cover Claude Code on this Mac. claude.ai, the desktop app and your other machines aren't included. Counting starts when you turn telemetry on rather than backfilling old transcripts. Turning it off and on again starts a new count, which OpenTelemetry tools see as a counter reset.

### Events

| Event (`event.name`) | When |
|---|---|
| `limit.reset` | A limit's usage dropped back as its window rolled over |
| `limit.severity_changed` | A limit moved between normal, warning and critical |
| `limit.appeared`, `limit.disappeared` | A limit showed up in or dropped out of the API response (a new per-model limit, say) |
| `extra_usage.enabled_changed` | Extra usage was switched on or off |
| `guest_pass.available`, `guest_pass.gone` | Guest passes became available, or one was redeemed or withdrawn |
| `credit_grant.available`, `credit_grant.gone` | A promotional credit was offered, or stopped being offered |

The API doesn't say why an offer went away, so `gone` events carry an `inferred_reason`. A guest pass that's no longer counted was redeemed (`used`). If you stop being eligible for passes altogether, they're `expired`. A credit grant is `used` if the API marks it granted, or if your headroom jumped at the same moment: the extra-usage cap went up, or a limit's usage fell without its window resetting. Otherwise it's `expired`.

Guest passes and credit grants come from the same account endpoints Claude Code uses for `/passes` and its promotions. They aren't a documented API, so if one stops answering, that part is skipped and everything else is still recorded. Your referral code and link are never written.

### Reading it with the OpenTelemetry Collector

The [OTLP JSON file receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/otlpjsonfilereceiver) (`otlp_json_file`; older Collector releases call it `otlpjsonfile`) reads these files as they are. From there you can export to whatever backend you use:

```yaml
receivers:
  otlp_json_file:
    # The receiver starts at the end of each file by default, which would skip history.
    start_at: beginning
    include:
      - "/Users/you/Documents/ClaudeBar Telemetry/*.jsonl"
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    metrics:
      receivers: [otlp_json_file]
      exporters: [debug]
    logs:
      receivers: [otlp_json_file]
      exporters: [debug]
```

## How it works

ClaudeBar polls `GET https://api.anthropic.com/api/oauth/usage` (once a minute, plus on menu open when stale) with the Claude Code OAuth token, and renders the `limits` array it gets back — one row per limit with percent used, a progress bar, and "Resets 5:00 pm · in 4h 55m" converted from UTC to your system timezone. The app is an accessory (no Dock icon, no app switcher entry); it just lives in the menu bar.

## Keychain access

By default ClaudeBar reads one Keychain item — Claude Code's `Claude Code-credentials` — to get the OAuth token the usage endpoint needs. In this mode it only reads: it never writes the item, refreshes the token, or touches the refresh token.

macOS gates that read behind a consent prompt. Click **Always Allow** and macOS trusts ClaudeBar for that item — until Claude Code next rotates its token. Claude Code refreshes its OAuth token a couple of times a day, and every refresh rewrites the Keychain item, which clears the item's list of trusted apps. So the prompt comes back and you grant it again. It isn't a bug in ClaudeBar or a setting that didn't save; macOS treats a rewritten item as new and re-checks who's allowed to read it.

### Stop the prompt: self-contained sign-in

**Settings → Usage data source → Self-contained sign-in** does its own OAuth login and stores the token in a Keychain item ClaudeBar created. Because ClaudeBar owns that item, macOS never runs the cross-app consent prompt, and Claude Code's rotations don't touch it — so the prompt stops.

It works because ClaudeBar now holds its own token pair: refreshing rotates *its* refresh token, never Claude Code's, so the CLI stays logged in. That's the trap the obvious "just refresh the token ourselves" idea falls into — Anthropic's refresh tokens are single-use, so refreshing Claude Code's copy logs the CLI out (an unrelated menu bar app hit exactly that: [CodexBar #1161](https://github.com/steipete/CodexBar/issues/1161)). Doing our own login avoids it. If the self-contained token ever fails, ClaudeBar falls back to Claude Code's token, so the worst case is the prompt you already know.

One caveat: sign-in reuses Claude Code's own OAuth client, since there's no public third-party OAuth for this endpoint. It's the same "act as Claude Code" posture as the `claude-code` User-Agent ClaudeBar already sends, and it could break if Anthropic changes the flow — the fallback keeps the app working if it does.

The default stays read-only and prompt-bearing; self-contained is opt-in.

## Dev loop

```sh
make run    # swift run, straight from source
make test   # swift test — core logic is fully unit-tested
```

The core library (`ClaudeBarCore`) holds everything testable: ISO8601 parsing, timezone formatting, severity thresholds, JSON decoding that survives unknown limit kinds. The app target is a thin SwiftUI `MenuBarExtra` on top.

## Releasing

Tag `vX.Y`, publish a GitHub release for it, and CI does the rest: signs with Developer ID, notarizes, staples, uploads the DMG, and pushes the updated cask to [the tap](https://github.com/GordonBeeming/homebrew-tap) so `brew upgrade --cask gordonbeeming/tap/claude-bar` picks it up.

## License

[MIT](LICENSE). The Claude name and logomark belong to Anthropic, and the license grants no trademark or copyright rights in them; see [TRADEMARKS.md](TRADEMARKS.md).
