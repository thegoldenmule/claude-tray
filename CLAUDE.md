# ClaudeTray

Native macOS menu bar app (Swift 6, SwiftPM, AppKit + SwiftUI) showing Claude usage limits.
See README.md for how it works, building, and releasing.

## Workflow

- **Commit as you go.** Commit each coherent, working change as soon as it builds and
  `make test` passes, without waiting to be asked. Don't leave finished work uncommitted
  across turns. Small, focused commits with messages that say why.
- Push and release only when asked (`git push`, `make release`).
- Work in this repo. Sibling repos (e.g. `../claude-watcher`) are reference material: read
  them, and change them only when explicitly asked (then follow that repo's CLAUDE.md). Never
  offer to.

## Commands

- `make test`: unit tests (pace math, response parsing, update check).
- `make run`: build, install to `~/Applications`, relaunch. Use it to check UI changes in
  the real menu bar and panel.
- `RELEASE_AUTH=xcode make release VERSION=X.Y.Z`: release. The script needs main clean and
  pushed. Use the Xcode account: Apple refuses cloud-managed Developer ID signing to App
  Store Connect API keys (403), even Admin ones.

## UI

- Keep the panel terse. Prefer encoding information in the bar (labels, tick, colour) over
  lines of caption text, and drop anything a glance at the bar already tells you.
