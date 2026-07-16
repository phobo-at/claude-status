#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA="${ROOT_DIR}/.build/local"
DIST_DIR="${ROOT_DIR}/.build/local-output"
SOURCE_APP="${DERIVED_DATA}/Build/Products/Release/ClaudeStatus.app"
OUTPUT_APP="${DIST_DIR}/ClaudeStatus.app"
ENTITLEMENTS="${ROOT_DIR}/ClaudeStatus/ClaudeStatus.entitlements"
LOCAL_SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY:-}"

if [[ -z "${LOCAL_SIGNING_IDENTITY}" ]]; then
  LOCAL_SIGNING_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' \
      | /usr/bin/head -n 1
  )"
fi

if [[ -z "${LOCAL_SIGNING_IDENTITY}" ]]; then
  LOCAL_SIGNING_IDENTITY="-"
  echo "Hinweis: Kein Apple-Development-Zertifikat gefunden; lokaler Build wird ad hoc signiert."
fi

"${SCRIPT_DIR}/security-check.sh"

mkdir -p "${DIST_DIR}"
rm -rf "${DERIVED_DATA}" "${OUTPUT_APP}"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec "${ROOT_DIR}/project.yml"
fi

xcodebuild \
  -quiet \
  -project "${ROOT_DIR}/ClaudeStatus.xcodeproj" \
  -scheme ClaudeStatus \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build

/usr/bin/ditto "${SOURCE_APP}" "${OUTPUT_APP}"

/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${LOCAL_SIGNING_IDENTITY}" \
  "${OUTPUT_APP}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"
echo "Nur lokaler Testbuild, nicht zur internen Verteilung freigegeben: ${OUTPUT_APP}"
echo "Lokale Signatur: ${LOCAL_SIGNING_IDENTITY}"
