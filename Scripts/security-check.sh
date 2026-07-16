#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
cd "${ROOT_DIR}"
swift_files=(ClaudeStatus/**/*.swift(N))

fail() {
  echo "Security-Check fehlgeschlagen: $1"
  exit 1
}

if /usr/bin/grep -nE 'Process[[:space:]]*\(' "${swift_files[@]}" >/dev/null; then
  fail "Produktionscode darf keine externen Programme starten."
fi

if /usr/bin/grep -nE '(NSLog[[:space:]]*\(|os_log[[:space:]]*\(|Logger[[:space:]]*\(|print[[:space:]]*\()' "${swift_files[@]}" >/dev/null; then
  fail "Produktionscode darf keine Laufzeitdaten protokollieren."
fi

unexpected_urls="$(
  /usr/bin/grep -nE '"https?://' "${swift_files[@]}" \
    | /usr/bin/grep -vF 'https://api.anthropic.com/api/oauth/usage' \
    || true
)"
if [[ -n "${unexpected_urls}" ]]; then
  echo "${unexpected_urls}"
  fail "Unerwartete Netzwerkadresse im Produktionscode."
fi

sandbox_value="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' ClaudeStatus/ClaudeStatus.entitlements 2>/dev/null || true)"
network_value="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' ClaudeStatus/ClaudeStatus.entitlements 2>/dev/null || true)"
[[ "${sandbox_value}" == "true" ]] || fail "App Sandbox ist nicht aktiviert."
[[ "${network_value}" == "true" ]] || fail "Nur der ausgehende Netzwerkzugriff muss aktiviert sein."

entitlement_keys="$(/usr/libexec/PlistBuddy -c 'Print' ClaudeStatus/ClaudeStatus.entitlements | /usr/bin/grep -Ec '^    [A-Za-z0-9.-]+ = ' | tr -d ' ')"
[[ "${entitlement_keys}" == "2" ]] || fail "Die App fordert unerwartete zusätzliche Entitlements an."

echo "Security-Check bestanden."
