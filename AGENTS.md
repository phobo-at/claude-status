# AGENTS.md

Guidance for coding agents (Codex and friends) working in this repository.

## What this is

**Claude Status** is a native macOS menu-bar app (SwiftUI `MenuBarExtra`, `LSUIElement` — no Dock
icon) that shows the signed-in user's personal Claude / Claude Code usage windows. Apple Silicon
only, macOS 14+, Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. No external Swift packages, no
telemetry.

## Read CLAUDE.md first

`CLAUDE.md` in this directory is the **single source of truth** for architecture, build and test
commands, the localization rules, and the security invariants. It is written for every agent, not
just Claude Code — read it before changing anything, and do not fork its content into this file.

Everything below is a summary of the parts that are easy to break by accident.

## Hard constraints

`Scripts/security-check.sh` fails the build (and CI) if production code under `ClaudeStatus/`
violates any of these:

1. **No subprocess launching** — no `Process(...)`. The app never runs `claude auth login` for the
   user; it only copies the command to the clipboard.
2. **No runtime logging** — no `print`, `NSLog`, `os_log`, or `Logger(...)`. The OAuth access token
   must never reach a log. Debug with tests, not logging.
3. **Exactly one network address** — the only allowed URL literal is
   `https://api.anthropic.com/api/oauth/usage`.
4. **Entitlements are exactly two** — `com.apple.security.app-sandbox` and
   `com.apple.security.network.client`, both true.

If a change genuinely needs a new URL or entitlement, update `security-check.sh` in the same commit
and justify it — it is the guardrail, not an obstacle to route around. `SECURITY.md` and
`PRIVACY.md` are the promises these back.

## Things that bite

- **Credentials.** `KeychainCredentialProvider` reads exactly the generic-password item
  `service = "Claude Code-credentials"`, `account = NSUserName()`. No fuzzy matching, no fallback.
  Claude Code rotates that item roughly daily, which is why a `401` on an in-memory token triggers
  one keychain re-read and one retry.
- **Localization.** Source strings are English and live in
  `ClaudeStatus/Resources/Localizable.xcstrings`; German is a translation. New user-facing copy needs
  the English literal, a German translation in the catalog, **and** the key added to
  `LocalizationTests`. A key the catalog lacks fails silently at runtime — that test is the only
  guard.
- **`project.yml` is the source of truth** for project settings and versions; the checked-in
  `ClaudeStatus.xcodeproj` is generated from it via `xcodegen generate --spec project.yml`. Bump
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` there, never in the xcodeproj.
- **Endpoint budget.** Anthropic rate-limits `/api/oauth/usage` per account and Claude Code polls the
  same endpoint on the same account, so the budget is shared. Polling is adaptive: slow while usage is
  flat, faster only while consecutive fetches show it climbing, clamped back on any 429. Do not
  tighten the cadences.

## Commands

```sh
# Full test suite (arm64)
xcodebuild -project ClaudeStatus.xcodeproj -scheme ClaudeStatus \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/ClaudeStatusDerivedData \
  CODE_SIGNING_ALLOWED=NO test

# Static security policy — MUST pass before every commit/push
./Scripts/security-check.sh

# Internal shareable build — ad-hoc signed, deliberately UNNOTARIZED → dist/ (this is what CI runs)
./Scripts/build-shareable.sh
```

`CLAUDE.md` documents the rest: single-test runs, the local dev build, and the notarized release
path.
