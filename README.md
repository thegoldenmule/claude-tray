# ClaudeTray

A tiny native macOS menu bar app that shows your Claude usage limits at a glance.
The menu bar shows a progress bar for the current session (5-hour) window; click it
for a panel with both the session and weekly limits and when each resets.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+ or Command Line Tools)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in
  with a Claude Pro or Max subscription

## How it works

- Reads Claude Code's OAuth access token from the login Keychain item
  `Claude Code-credentials` by shelling out to `/usr/bin/security`. The first time,
  macOS will ask whether to allow this; choose "Always Allow".
- Calls the undocumented `GET https://api.anthropic.com/api/oauth/usage` endpoint
  and displays the `five_hour` (session) and `seven_day` (weekly) utilization.
- Never refreshes or writes the token. If it has expired, the app shows stale data
  until Claude Code refreshes it (just use Claude Code as normal).
- Polls every 5 minutes, backing off on HTTP 429. Opening the panel triggers a
  refresh, throttled to once per minute.

## Build and run

```sh
make dev       # swift run, no app bundle (quick iteration)
make app       # release build -> build/ClaudeTray.app, codesigned
make run       # build the app, quit any running copy, and launch it
make install   # build and copy to ~/Applications/ClaudeTray.app
make clean
```

`make app` signs with your first "Apple Development" identity if you have one,
otherwise ad-hoc. Override with `make app SIGN_IDENTITY="..."`.

## Launch at login

Run `make install`, open `~/Applications/ClaudeTray.app`, and enable
"Launch at login" in the panel. This registers the app with `SMAppService`, so it
should be enabled from the installed copy rather than `build/`.

## Caveats

- The usage endpoint is undocumented and may change or disappear without notice.
- Requests count against the same account rate limits Claude Code uses, which is
  why polling is deliberately infrequent.
- Not affiliated with or endorsed by Anthropic.

## License

MIT. See [LICENSE](LICENSE).
