# ClaudeBar

A tiny macOS menu bar app that shows my Claude usage limits: session, weekly, and per-model percentages, without having to open a terminal or a browser tab. Reset times show up in my local timezone. It renders a cached value instantly on click, then refreshes in the background, so there's no lag waiting on a network call.

## Requirements

- macOS 15+
- Claude Code installed and logged in

ClaudeBar reads the Claude Code OAuth token straight out of the macOS Keychain. It never writes to it or refreshes the token; that's Claude Code's job. If the token has expired, ClaudeBar shows a hint to re-run `claude` and log in again rather than failing silently.

## Install

```
make install
```

This builds a release binary, bundles it into `dist/ClaudeBar.app`, and copies it to `~/Applications/ClaudeBar.app`. Then:

```
open ~/Applications/ClaudeBar.app
```

The first time it reads the Keychain item, macOS will ask for your permission. Click **Always Allow** so you're not prompted again.

That "always allow" grant is tied to the app's code signature. `make install` signs with a real Apple Development identity if `security find-identity` finds one, falling back to ad-hoc signing (`-`) if it doesn't. Ad-hoc signing mints a fresh identity on every build, so with it you'll get the Keychain prompt again after every rebuild. A proper dev identity keeps the same signature across builds, so you only see the prompt once, ever. If you have an Apple Development certificate in your keychain, this happens automatically, no setup needed.

## Dev loop

```
make run    # swift run, straight from source
make test   # swift test
```

## Launch at login

Toggle "Launch at Login" from the menu bar item. ClaudeBar runs as an accessory app with no Dock icon and no app switcher entry; it's meant to just sit in the menu bar.

## How it works

ClaudeBar calls `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token from Keychain, then renders the `limits` array it gets back — one entry per scope (session, weekly, per-model), each with a percentage used and a reset time. Reset times are converted from UTC to your system timezone before display.

There's no polling loop hammering the API — it refreshes on click and on a light background interval, and always shows the last good value while a refresh is in flight.
