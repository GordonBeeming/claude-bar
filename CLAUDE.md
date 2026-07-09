# ClaudeBar — agent notes

## Automation

After a code change that affects the built app, install it locally automatically — don't wait to be asked:

```bash
make install
```

`make install` builds a release binary, signs it with the Apple Development identity, copies it to `~/Applications/ClaudeBar.app`, and kills the running instance so the next launch picks up the change. Relaunch with `open ~/Applications/ClaudeBar.app`.

Skip it only when Gordon says not to for a specific change, or when the change is docs/tests-only with nothing to run.

## Build & test

- `swift build` / `swift test` for a quick loop.
- `make bundle` produces the signed `.app` under `dist/` without installing.
