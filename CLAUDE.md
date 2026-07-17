# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Claude Status is a native macOS **menu-bar app** (SwiftUI `MenuBarExtra`, `LSUIElement` — no Dock icon) that shows the signed-in user's personal Claude / Claude Code usage windows. Apple Silicon only, macOS 14+, Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. No external Swift packages, no telemetry.

User-facing strings are **German** (`de_AT` locale); keep new UI copy German to match.

## Commands

```sh
# Open in Xcode
open ClaudeStatus.xcodeproj

# Run the full test suite (arm64)
xcodebuild -project ClaudeStatus.xcodeproj -scheme ClaudeStatus \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/ClaudeStatusDerivedData \
  CODE_SIGNING_ALLOWED=NO test

# Run a single test (or class): append -only-testing
#   -only-testing:ClaudeStatusTests/UsageStoreTests/testConnectFetchesAndCachesUsage
#   -only-testing:ClaudeStatusTests/UsageClientTests

# Static security policy (MUST pass before every commit/push; see below)
./Scripts/security-check.sh

# Local ad-hoc/dev-signed test build → .build/local-output/ClaudeStatus.app (NOT packaged, NOT for distribution)
./Scripts/build-local.sh

# Internal shareable build — ad-hoc signed, deliberately UNNOTARIZED → dist/ (ZIP + .sha256 only)
# (no Developer ID needed; the UNNOTARIZED marker stays in the filename; this is what CI runs)
./Scripts/build-shareable.sh

# Official notarized release — requires Developer ID + notarization, refuses (exit 64) otherwise → dist/release/
DEVELOPER_ID_APPLICATION="Developer ID Application: ORG (TEAMID)" \
  NOTARY_PROFILE="ClaudeStatus-Notary" ./Scripts/build-notarized.sh
```

CI (`.github/workflows/ci.yml`, macos-26 arm64) runs security-check → tests → the unnotarized internal package (`build-shareable.sh`) on every push/PR.

### XcodeGen

`project.yml` is the source of truth for project settings; `ClaudeStatus.xcodeproj` is **checked in and generated from it**. If you change `project.yml` (targets, build settings, version), run `xcodegen generate --spec project.yml` to regenerate — the build scripts do this automatically when `xcodegen` is on PATH. Bump versions in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), not in the xcodeproj.

## Architecture

Single data flow, protocol-injected for testability. `UsageStore` is the one source of truth; everything else is a swappable dependency behind a protocol.

- **`ViewModels/UsageStore.swift`** — `@MainActor` `ObservableObject`, the central state machine. Owns the `UsageDisplayState` enum (`disconnected` / `loading` / `current` / `stale` / `authenticationRequired` / `failed`), the 15-min polling task (`automaticRefreshInterval`), and two independent cool-down gates: `retryAfterUntil` (armed only by an Anthropic `Retry-After`) blocks **every** caller including explicit user actions, while `automaticBackoffUntil` (exponential `[60,120,300,900]` on any transient failure) throttles **only** automatic refreshes — `refresh(force: true)` bypasses it, so a self-imposed backoff never disables the user's refresh button. Automatic triggers — the poll loop, popover-open, and wake-from-sleep — all funnel through `refreshAutomaticallyIfStale()`, which skips the fetch while the snapshot is younger than `minimumAutomaticRefreshAge` (10 min); only explicit user actions force a refresh. Injects `CredentialProviding`, `UsageFetching`, `SnapshotCaching`, `UserDefaults`, and a `now` closure — all tests construct it with fakes and a fixed clock.
- **`Services/CredentialProvider.swift`** — `KeychainCredentialProvider` reads exactly the generic-password item `service = "Claude Code-credentials"`, `account = NSUserName()`. No fuzzy matching, no legacy fallback. Decodes `claudeAiOauth.accessToken` (+ `subscriptionType` → plan name). Read once per app start and kept in memory only — plus one re-read whenever the held token is rejected, since Claude Code rotates that item roughly daily (see the rotation rule below).
- **`Services/UsageClient.swift`** — `AnthropicUsageClient` GETs `https://api.anthropic.com/api/oauth/usage` with the token as a Bearer header. Endpoint is allowlisted via `AnthropicUsageEndpoint.isAllowed` (scheme/host/path/no query/no creds), redirects are rejected (`RedirectRejectingDelegate`), session is `.ephemeral` (no cookies/cache). Maps HTTP status → `UsageClientError` (401/403 → `unauthorized`, 429 → `rateLimited`, etc.).
- **`Models/UsageModels.swift`** — `UsagePayload` (wire format: `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`) → `UsageSnapshot` (domain: `currentSession`, `weeklyAllModels`, `weeklySonnet`, `weeklyOpus`). `LimitWindow` clamps utilization to 0–100; dates parsed via `FlexibleISO8601Date` (with/without fractional seconds).
- **`Services/SnapshotCache.swift`** — `FileSnapshotCache` actor persists the last snapshot to `Application Support/ClaudeStatus/usage-cache.json` (dir `0700`, file `0600`). Only cached artifact; write failures are swallowed (network is authoritative).
- **`Views/`** — `MenuBarLabel` (progress ring + %), `StatusPopoverView` (the `.window`-style popover), `UsageRowView`. `App/ClaudeStatusApp.swift` wires `MenuBarExtra` and drives `store.start()` / `store.popoverOpened()`.
- **`Utilities/UsageFormatting.swift`** — pure `de_AT` string builders (percentage, session/weekly reset countdowns, "updated N minutes ago"). All user-facing German copy funnels through here; keep it deterministic (takes injectable `now`/`calendar`/`timeZone`) so `UsageFormattingTests` can pin it.

State transitions worth knowing (all verified by `UsageStoreTests`):

- **Token rotation.** Claude Code refreshes its OAuth token roughly daily and rewrites the keychain item, which silently invalidates the token this app is holding. So a `401` on the **in-memory** token triggers exactly one keychain re-read and one retry — no user action, no dialog: the keychain grant is bound to the app's code identity and survives the item's data being rewritten. A `401` on a **freshly read** token is a real login problem: it surfaces as `authenticationRequired` and stops automatic keychain reads until an explicit user retry. That bounds any refresh at two requests and one keychain read.
- **First-run consent** is gated behind the `hasAuthorizedClaudeCodeConnection` UserDefaults flag — the app starts `disconnected` and never touches the keychain until the user presses "connect".

Endpoint budget: Anthropic rate-limits `/api/oauth/usage` **per account** (429 + a `Retry-After` of ~1800s), and Claude Code polls the same endpoint on the same account, so the budget is shared. That is why `automaticRefreshInterval`/`minimumAutomaticRefreshAge` are deliberately slow — every window the app displays moves over hours or days. When `retryAfterUntil` is armed the refresh button is disabled, so the popover **must** keep showing `store.activeRetryAfter` ("Neuer Versuch um HH:mm"); a dead button with no explanation reads as a broken app.

## Security invariants (enforced by `Scripts/security-check.sh`)

These are hard constraints on production code under `ClaudeStatus/`. The script fails the build (and CI) if any is violated, so changes must respect them:

1. **No subprocess launching** — no `Process(...)`. The app never runs `claude auth login` for the user; it only copies the command to the clipboard.
2. **No runtime logging** — no `print`, `NSLog`, `os_log`, or `Logger(...)`. The access token must never reach a log. Debug with tests, not logging.
3. **Exactly one network address** — the only allowed URL literal is `https://api.anthropic.com/api/oauth/usage`. Any other `http(s)://` literal fails the check.
4. **Entitlements are exactly two** — `com.apple.security.app-sandbox` and `com.apple.security.network.client`, both true (`ClaudeStatus.entitlements`). Adding any entitlement fails the check.

If you must add a URL or entitlement for a legitimate reason, update `security-check.sh` in the same change and justify it — it is the guardrail, not an obstacle to route around. See `SECURITY.md` / `PRIVACY.md` for the full promise.
