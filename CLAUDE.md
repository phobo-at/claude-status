# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Claude Status is a native macOS **menu-bar app** (SwiftUI `MenuBarExtra`, `LSUIElement` — no Dock icon) that shows the signed-in user's personal Claude / Claude Code usage windows. Apple Silicon only, macOS 14+, Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. No external Swift packages, no telemetry.

User-facing strings are **localized, English-source**: every literal in the code is English and lives in `ClaudeStatus/Resources/Localizable.xcstrings`, with German as a translation. macOS picks the language from the user's preferences — that needs no code, but it does need the language listed under `knownRegions` in `project.yml`. New UI copy therefore goes in English **and** gets a German translation in the catalog; see the localization rules below.

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

- **`ViewModels/UsageStore.swift`** — `@MainActor` `ObservableObject`, the central state machine. Owns the `UsageDisplayState` enum (`disconnected` / `loading` / `current` / `stale` / `authenticationRequired` / `failed`), the adaptive polling task, and two independent cool-down gates: `retryAfterUntil` (armed only by an Anthropic `Retry-After`) blocks **every** caller including explicit user actions, while `automaticBackoffUntil` (exponential `[60,120,300,900]` on any transient failure) throttles **only** automatic refreshes — `refresh(force: true)` bypasses it, so a self-imposed backoff never disables the user's refresh button. Automatic triggers — the poll loop, popover-open, system wake, and display wake — all funnel through `refreshAutomaticallyIfStale(minimumAge:)`, which skips the fetch while the snapshot is younger than that age; only explicit user actions force a refresh. The gate is split by intent: background triggers use the cadence's age (below), while popover-open — the user deliberately asking — uses `minimumInteractiveRefreshAge` (3 min), still bounded at one request per interval and still subject to the backoff. The poll cadence itself is **adaptive** (`PollingCadence`): idle is 15 min / 10 min gate, active is 5 min / 4 min gate. A fetch whose utilization *increased* since the previous one (`UsageSnapshot.showsIncreasedUsage(since:)` — increases only; a drop is a window reset, not activity) within `activityComparisonWindow` (30 min) switches to active; `idleConfirmationCount` (2) flat fetches drop back to idle, and any 429 clamps to idle immediately. The freshness argument: a stale percentage is only *visibly* stale while usage climbs, so the fast cadence runs exactly when staleness would show, and idle time pays for it — steady-state spend stays at ~4 calls/h. Polls are one-shot tasks re-armed via the pure `nextPollDelay(lastFetchedAt:interval:backoffUntil:retryAfterUntil:now:)`, **anchored to the last successful fetch** — an off-cycle refresh (popover, wake, reset) pushes the next tick out instead of letting it fire early and skip against its own gate, which used to stretch worst-case staleness to interval + gate. On top of that, every accepted snapshot arms a one-shot `resetRefreshTask` for `resetsAt + resetRefreshGrace` of the earliest window inside `resetRefreshHorizon` (6 h), so the percentage drops the moment the window actually rolls over instead of at the next tick. Both scheduling decisions are pure statics (`resetRefreshDelay(for:now:)`, `nextPollDelay(...)`), which is what the tests assert; a reset Anthropic hasn't rolled over yet yields a non-positive delay and simply doesn't rearm, so it can never become a retry loop. Injects `CredentialProviding`, `UsageFetching`, `SnapshotCaching`, `UserDefaults`, and a `now` closure — all tests construct it with fakes and a fixed clock.
- **`Services/CredentialProvider.swift`** — `KeychainCredentialProvider` reads exactly the generic-password item `service = "Claude Code-credentials"`, `account = NSUserName()`. No fuzzy matching, no legacy fallback. Decodes `claudeAiOauth.accessToken` (+ `subscriptionType` → plan name). Read once per app start and kept in memory only — plus one re-read whenever the held token is rejected, since Claude Code rotates that item roughly daily (see the rotation rule below).
- **`Services/UsageClient.swift`** — `AnthropicUsageClient` GETs `https://api.anthropic.com/api/oauth/usage` with the token as a Bearer header. Endpoint is allowlisted via `AnthropicUsageEndpoint.isAllowed` (scheme/host/path/no query/no creds), redirects are rejected (`RedirectRejectingDelegate`), session is `.ephemeral` (no cookies/cache). Maps HTTP status → `UsageClientError` (401/403 → `unauthorized`, 429 → `rateLimited`, etc.).
- **`Models/UsageModels.swift`** — `UsagePayload` (wire format: `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`) → `UsageSnapshot` (domain: `currentSession`, `weeklyAllModels`, `weeklySonnet`, `weeklyOpus`). `LimitWindow` clamps utilization to 0–100; dates parsed via `FlexibleISO8601Date` (with/without fractional seconds).
- **`Services/SnapshotCache.swift`** — `FileSnapshotCache` actor persists the last snapshot to `Application Support/ClaudeStatus/usage-cache.json` (dir `0700`, file `0600`). Only cached artifact; write failures are swallowed (network is authoritative).
- **`Views/`** — `MenuBarLabel` (progress ring + %), `StatusPopoverView` (the `.window`-style popover), `UsageRowView`. `App/ClaudeStatusApp.swift` wires `MenuBarExtra` and drives `store.start()` / `store.popoverOpened()`.
- **`Utilities/UsageFormatting.swift`** — the string builders (percentage, session/weekly reset countdowns, "updated N minutes ago", the `Retry-After` hint). All localized copy that is not a plain SwiftUI `Text` funnels through here. Keep it deterministic: it takes injectable `now`/`calendar`/`timeZone`/`locale`/`bundle` so `UsageFormattingTests` can pin every one. `locale` and `bundle` are **not** interchangeable — see below.

State transitions worth knowing (all verified by `UsageStoreTests`):

- **Token rotation.** Claude Code refreshes its OAuth token roughly daily and rewrites the keychain item, which silently invalidates the token this app is holding. So a `401` on the **in-memory** token triggers exactly one keychain re-read and one retry — no user action, no dialog: the keychain grant is bound to the app's code identity and survives the item's data being rewritten. A `401` on a **freshly read** token is a real login problem: it surfaces as `authenticationRequired` and stops automatic keychain reads until an explicit user retry. That bounds any refresh at two requests and one keychain read.
- **First-run consent** is gated behind the `hasAuthorizedClaudeCodeConnection` UserDefaults flag — the app starts `disconnected` and never touches the keychain until the user presses "connect".

Endpoint budget: Anthropic rate-limits `/api/oauth/usage` **per account** (429 + a `Retry-After` of ~1800s), and Claude Code polls the same endpoint on the same account, so the budget is shared. That is why the idle cadence (`automaticRefreshInterval`/`minimumAutomaticRefreshAge`) is deliberately slow and the active cadence is both bounded (≤12 calls/h, only while fetches keep showing climbing utilization) and self-clamping on any 429 — do not tighten either without revisiting this shared budget. When `retryAfterUntil` is armed the refresh button is disabled, so the popover **must** keep showing `store.activeRetryAfter` ("Neuer Versuch um HH:mm"); a dead button with no explanation reads as a broken app.

## Localization

Source strings are **English**, in `ClaudeStatus/Resources/Localizable.xcstrings`; German is a translation. `project.yml` sets `developmentLanguage: en` and lists `knownRegions: [en, de]`. Only `de.lproj` ships — English *is* the key, so any system language without an `.lproj` falls back to `CFBundleDevelopmentRegion` (en) and renders the source strings. Language selection is macOS's job; the app has no language setting and no code for it.

Adding user-facing copy:

1. Write the literal in English in the code. SwiftUI `Text`/`Button`/`Label`/`.help` take `LocalizedStringKey` and localize on their own; anything returning a plain `String` (error `errorDescription`, `UsageFormatting`) must use `String(localized:)` explicitly.
2. Add the key **and** a German translation to `Localizable.xcstrings`.
3. Add the key to the list in `LocalizationTests`.

**`locale:` and `bundle:` are not interchangeable — this is the trap.** In `String(localized:bundle:locale:)`, the **`bundle` selects the language**; `locale:` only formats interpolated values (numbers, dates). `String(localized: "…", locale: Locale(identifier: "en_US"))` on a German Mac still returns **German**. So:

- `UsageFormatting` takes both: `bundle` for the language, `locale` for the clock and the weekday. Dates must follow the user's *locale*, not the UI language — the formatters used to hardcode `de_AT`, which gave every user Austrian dates.
- Tests must pin `bundle:` to `de.lproj` explicitly. Relying on the ambient language makes the suite pass locally (German Mac) and fail on CI (English runner), or vice versa.

A key the code asks for that the catalog lacks **fails silently**: the lookup returns the English key, so nothing crashes and a German user just sees English. `LocalizationTests` is the only guard — it asserts every key has a German translation, that the translation is not verbatim English, and that placeholder specifiers (`%lld`, `%@`, `%d`) survive translation. `UsageFormattingTests` covers the other half by asserting the German round-trip through the real code paths, which is what proves the key the code *generates* matches the key in the catalog.

## Security invariants (enforced by `Scripts/security-check.sh`)

These are hard constraints on production code under `ClaudeStatus/`. The script fails the build (and CI) if any is violated, so changes must respect them:

1. **No subprocess launching** — no `Process(...)`. The app never runs `claude auth login` for the user; it only copies the command to the clipboard.
2. **No runtime logging** — no `print`, `NSLog`, `os_log`, or `Logger(...)`. The access token must never reach a log. Debug with tests, not logging.
3. **Exactly one network address** — the only allowed URL literal is `https://api.anthropic.com/api/oauth/usage`. Any other `http(s)://` literal fails the check.
4. **Entitlements are exactly two** — `com.apple.security.app-sandbox` and `com.apple.security.network.client`, both true (`ClaudeStatus.entitlements`). Adding any entitlement fails the check.

If you must add a URL or entitlement for a legitimate reason, update `security-check.sh` in the same change and justify it — it is the guardrail, not an obstacle to route around. See `SECURITY.md` / `PRIVACY.md` for the full promise.
