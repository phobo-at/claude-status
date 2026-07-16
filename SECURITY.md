# Security Policy

## Data flow

1. Only after an explicit click on "Mit Claude Code verbinden" does the app query the local macOS Keychain for exactly one item: service `Claude Code-credentials`, account = current macOS username.
2. From the JSON, only `claudeAiOauth.accessToken` and optionally `subscriptionType` are decoded. Unknown or older structures are rejected and not searched recursively.
3. The access token is read once per app process, reused in memory for the periodic fetches, and used as `Authorization: Bearer …`. After an authentication error the reference is discarded; automatic fetches do not read the Keychain again.
4. The only destination address allowed in production code is `https://api.anthropic.com/api/oauth/usage`. Redirects are not followed.
5. Only percentages, reset timestamps, and the fetch timestamp are stored. Credentials are not part of the cache model.

The access token necessarily leaves the device in the TLS-protected request to Anthropic. Without this authentication the personal usage endpoint cannot be queried. It is never transmitted to colleagues, this repository, any own server, or a third party.

## Platform protection

- App Sandbox: enabled
- Sandbox entitlements: exclusively `com.apple.security.app-sandbox` and `com.apple.security.network.client`
- Hardened Runtime: enabled, with no runtime exceptions
- App Transport Security: default rules, no exceptions
- Network: ephemeral `URLSession`, no cookies, no URL cache, TLS 1.2 as the minimum version
- Internal build: ad-hoc signed, clearly marked `UNNOTARIZED`; no Apple-confirmed publisher identity and no Apple notarization
- Optional official release path: Developer ID, secure timestamp, Apple notarization, stapling, and Gatekeeper check
- Architecture: arm64; no Intel binaries

macOS controls the Keychain access decision and any authorization dialog. The app does not write or modify any Claude Code Keychain item.

## Deliberately excluded capabilities

- no shell or process execution
- no Apple Events or automation
- no reading of arbitrary files in the home directory
- no import or export of credentials
- no built-in login form
- no telemetry, crash uploads, or analytics
- no update component
- no third-party dependencies

## Threat boundaries

The architecture does not protect against an already-compromised user account, operating system, or Claude Code Keychain item. System-wide proxies, installed root certificates, and endpoint-security products are under the control of the respective Mac or organization. The Anthropic endpoint used is undocumented; a change can render the app non-functional and must be re-audited before an update.

An absolute guarantee that a secret never appears in process memory is not possible with Bearer authentication. The app minimizes lifetime and persistence but has no API with which Swift strings or internal `URLSession` buffers could be reliably overwritten.

## Distribution model

`Scripts/build-shareable.sh` deliberately produces an ad-hoc-signed internal build as a ZIP and checksum file directly under `dist/`. Both permanently carry the `UNNOTARIZED` suffix. Recipients must expect a Gatekeeper warning and cannot verify the publisher identity through Apple. The SHA-256 checksum should be compared over a separate, trusted channel; the strongest check remains building it yourself from the audited source.

The project recommends neither globally disabling Gatekeeper nor bulk-removing quarantine attributes. If organizational policy requires a Developer ID signature, the unnotarized build must not be used.

`Scripts/build-notarized.sh` remains available as an optional, strict release path and aborts without a Developer ID identity or notarization profile.

## Reporting vulnerabilities

Please do not copy tokens, Keychain dumps, or personal data into public issues. For a public GitHub repository, enable the "Private vulnerability reporting" feature and use it for confidential reports.

## References

- [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple: Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Apple: Preventing Insecure Network Connections with ATS](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)
- [Apple: Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
