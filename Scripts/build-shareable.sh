#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA="${ROOT_DIR}/.build/internal-unnotarized"
DIST_DIR="${ROOT_DIR}/dist"
SOURCE_APP="${DERIVED_DATA}/Build/Products/Release/ClaudeStatus.app"
OUTPUT_APP="${DERIVED_DATA}/ClaudeStatus.app"
OUTPUT_ZIP="${DIST_DIR}/ClaudeStatus-Apple-Silicon-UNNOTARIZED.zip"
CHECKSUM_FILE="${OUTPUT_ZIP}.sha256"
ENTITLEMENTS="${ROOT_DIR}/ClaudeStatus/ClaudeStatus.entitlements"

"${SCRIPT_DIR}/security-check.sh"

mkdir -p "${DIST_DIR}"
rm -rf "${DERIVED_DATA}" "${OUTPUT_ZIP}" "${CHECKSUM_FILE}"

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

# Ad-hoc signing preserves bundle integrity and enforces the embedded sandbox
# entitlements, but it does not establish an Apple-verified publisher identity.
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --entitlements "${ENTITLEMENTS}" \
  --sign - \
  "${OUTPUT_APP}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"

architectures="$(/usr/bin/lipo -archs "${OUTPUT_APP}/Contents/MacOS/ClaudeStatus")"
if [[ "${architectures}" != "arm64" ]]; then
  echo "Build abgebrochen: Erwartet wurde ausschließlich arm64, gefunden: ${architectures}"
  exit 1
fi

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

echo ""
echo "UNNOTARISIERTER INTERNER BUILD"
echo "Diese App besitzt keine Developer-ID-Signatur und wurde nicht von Apple notarisiert."
echo "macOS wird beim ersten Start deshalb erwartungsgemäß warnen."
echo "ZIP: ${OUTPUT_ZIP}"
echo "SHA-256: ${CHECKSUM_FILE}"
