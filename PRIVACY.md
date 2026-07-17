# Privacy

Claude Status processes only the data needed to display usage limits locally.

## Data processed

- Claude Code OAuth access token: after user authorization, read once per app launch from the local macOS Keychain, reused in memory for further fetches, and used exclusively for the authenticated HTTPS request to Anthropic. It is read again only when Anthropic rejects the token held in memory — which happens when Claude Code refreshes its own login, roughly daily.
- Plan type: derived, if present, from the `subscriptionType` field of the same local Keychain payload.
- Usage data: percentages, reset timestamps, and the fetch timestamp from the Anthropic endpoint.
- Local setting: a boolean remembers whether the user has explicitly enabled the connection to the Claude Code login.

## Storage

The access token is not persisted by Claude Status. The local cache contains usage data only. In the app sandbox container, the cache file has POSIX permissions `0600` and its folder `0700`.

## Transmission

The only transmission initiated by the app goes via HTTPS to `api.anthropic.com`. It contains the OAuth access token in the Authorization header and no analytics or device identifiers added by Claude Status. There are no own backend systems and no sharing with colleagues or third parties by the app.

The missing Apple notarization does not change this implemented data flow, but it removes recipients' ability to verify the publisher identity through Apple. The binary package and checksum should therefore only be obtained from an agreed, trusted channel.

## Deletion

When removing the app, the associated sandbox container under `~/Library/Containers/io.github.phobo-at.ClaudeStatus` can be deleted. The Claude Code Keychain item belongs to Claude Code and is neither created nor deleted by Claude Status.
