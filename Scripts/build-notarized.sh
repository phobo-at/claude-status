#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA="${ROOT_DIR}/.build/release"
DIST_DIR="${ROOT_DIR}/dist/release"
SOURCE_APP="${DERIVED_DATA}/Build/Products/Release/ClaudeStatus.app"
OUTPUT_APP="${DIST_DIR}/ClaudeStatus.app"
OUTPUT_ZIP="${DIST_DIR}/ClaudeStatus-Apple-Silicon.zip"
CHECKSUM_FILE="${OUTPUT_ZIP}.sha256"
NOTARY_ZIP="${DIST_DIR}/ClaudeStatus-notarization.zip"
ENTITLEMENTS="${ROOT_DIR}/ClaudeStatus/ClaudeStatus.entitlements"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "${DEVELOPER_ID_APPLICATION}" || -z "${NOTARY_PROFILE}" ]]; then
  echo "Release abgebrochen: Developer-ID-Identität und Notarisierungsprofil fehlen."
  echo "Für den bewusst unnotarisierten internen Build: ./Scripts/build-shareable.sh"
  exit 64
fi

"${SCRIPT_DIR}/security-check.sh"

mkdir -p "${DIST_DIR}"
rm -rf "${DERIVED_DATA}" "${OUTPUT_APP}" "${OUTPUT_ZIP}" "${CHECKSUM_FILE}" "${NOTARY_ZIP}"

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
  --timestamp \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${DEVELOPER_ID_APPLICATION}" \
  "${OUTPUT_APP}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"

/usr/bin/ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  "${OUTPUT_APP}" \
  "${NOTARY_ZIP}"

xcrun notarytool submit \
  "${NOTARY_ZIP}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

xcrun stapler staple "${OUTPUT_APP}"
xcrun stapler validate "${OUTPUT_APP}"
/usr/sbin/spctl --assess --type execute --verbose=4 "${OUTPUT_APP}"

/usr/bin/ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  "${OUTPUT_APP}" \
  "${OUTPUT_ZIP}"

(
  cd "${DIST_DIR}"
  /usr/bin/shasum -a 256 "${OUTPUT_ZIP:t}" > "${CHECKSUM_FILE:t}"
)
rm -f "${NOTARY_ZIP}"

echo "Notarisierte App: ${OUTPUT_APP}"
echo "Notarisiertes ZIP: ${OUTPUT_ZIP}"
echo "Prüfsumme: ${CHECKSUM_FILE}"
