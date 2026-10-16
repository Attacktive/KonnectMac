#!/usr/bin/env bash
set -euo pipefail

# KonnectMac Release Packaging Script
# Builds universal Release archive, ad-hoc codesigns app, creates DMG and ZIP,
# generates appcast using official Sparkle generate_appcast, and validates signatures.

usage() {
	echo "Usage: $0 [options]"
	echo ""
	echo "Environment variables:"
	echo "  SPARKLE_PRIVATE_KEY         Sparkle EdDSA private key (required, never passed via arguments)"
	echo "  SPARKLE_PUBLIC_KEY          Sparkle EdDSA public key (base64, required if not provided via --sparkle-public-key)"
	echo ""
	echo "Options:"
	echo "  --version <version>         Release version (required, 1-3 numeric components, e.g. 2.7 or 2.7.0)"
	echo "  --tag <tag>                 Release tag name (default: matches the input version, or 'v<version>' if omitted)"
	echo "  --sparkle-public-key <key>  Sparkle EdDSA public key (base64)"
	echo "  --sparkle-feed-url <url>    Sparkle feed URL (default: https://github.com/Attacktive/KonnectMac/releases/latest/download/appcast.xml)"
	echo "  --download-url-prefix <url> Download URL prefix for appcast enclosures (default: https://github.com/Attacktive/KonnectMac/releases/download/<tag>/)"
	echo "  --sparkle-bin <path>        Path to directory containing Sparkle tools (default: looks in PATH or build/release-smoke/sparkle/bin)"
	echo "  --output-dir <path>         Output directory for release artifacts (default: build/artifacts)"
	echo "  -h, --help                  Show this help"
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RAW_VERSION=""
TAG_NAME=""
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/Attacktive/KonnectMac/releases/latest/download/appcast.xml}"
DOWNLOAD_URL_PREFIX=""
SPARKLE_BIN_DIR=""
OUTPUT_DIR="${REPO_ROOT}/build/artifacts"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version)
			RAW_VERSION="$2"
			shift 2
			;;
		--tag)
			TAG_NAME="$2"
			shift 2
			;;
		--sparkle-public-key)
			SPARKLE_PUBLIC_KEY="$2"
			shift 2
			;;
		--sparkle-feed-url)
			SPARKLE_FEED_URL="$2"
			shift 2
			;;
		--download-url-prefix)
			DOWNLOAD_URL_PREFIX="$2"
			shift 2
			;;
		--sparkle-bin)
			SPARKLE_BIN_DIR="$2"
			shift 2
			;;
		--output-dir)
			OUTPUT_DIR="$2"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Unknown option: $1" >&2
			usage
			;;
	esac
done

if [[ -z "${RAW_VERSION}" ]]; then
	echo "Error: --version is required." >&2
	exit 1
fi

# Strip optional leading 'v' to get numeric version
VERSION="${RAW_VERSION#v}"

# Restrict to 1-3 numeric components per Apple version contract (e.g. 2, 2.7, 2.7.0)
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
	echo "Error: Invalid version format '${RAW_VERSION}'. Must be 1-3 numeric components with optional leading v (e.g. 2, 2.7, 2.7.0)." >&2
	exit 1
fi

# If --tag was not provided, preserve the exact input if it started with v, or prefix with v
if [[ -z "${TAG_NAME}" ]]; then
	if [[ "${RAW_VERSION}" == v* ]]; then
		TAG_NAME="${RAW_VERSION}"
	else
		TAG_NAME="v${VERSION}"
	fi
fi

if [[ -z "${DOWNLOAD_URL_PREFIX}" ]]; then
	DOWNLOAD_URL_PREFIX="https://github.com/Attacktive/KonnectMac/releases/download/${TAG_NAME}/"
fi

if [[ "${DOWNLOAD_URL_PREFIX}" != */ ]]; then
	DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX}/"
fi

if [[ -z "${SPARKLE_PUBLIC_KEY}" ]]; then
	echo "Error: SPARKLE_PUBLIC_KEY is not set." >&2
	exit 1
fi

if [[ -z "${SPARKLE_PRIVATE_KEY}" ]]; then
	echo "Error: SPARKLE_PRIVATE_KEY environment variable is not set." >&2
	exit 1
fi

# Locate Sparkle binaries
if [[ -z "${SPARKLE_BIN_DIR}" ]]; then
	if [[ -x "${REPO_ROOT}/build/release-smoke/sparkle/bin/generate_appcast" ]]; then
		SPARKLE_BIN_DIR="${REPO_ROOT}/build/release-smoke/sparkle/bin"
	elif command -v generate_appcast >/dev/null 2>&1; then
		SPARKLE_BIN_DIR="$(dirname "$(command -v generate_appcast)")"
	fi
fi

if [[ -z "${SPARKLE_BIN_DIR}" ]] || [[ ! -x "${SPARKLE_BIN_DIR}/generate_appcast" ]] || [[ ! -x "${SPARKLE_BIN_DIR}/sign_update" ]]; then
	echo "Error: Sparkle tools (generate_appcast, sign_update) not found in '${SPARKLE_BIN_DIR}'. Specify --sparkle-bin <path>." >&2
	exit 1
fi

# Create a temporary staging workspace cleaned up on exit
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/konnectmac-package.XXXXXX")
cleanup() {
	rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

# Validate keypair match by signing a probe file via official sign_update and verifying with public key
PROBE_FILE="${TEMP_DIR}/key-probe.txt"
printf "KonnectMac-Key-Validation-%s" "${VERSION}" > "${PROBE_FILE}"
PROBE_SIGNATURE=$(printf "%s" "${SPARKLE_PRIVATE_KEY}" | "${SPARKLE_BIN_DIR}/sign_update" --ed-key-file - -p "${PROBE_FILE}" 2>/dev/null || true)

if [[ -z "${PROBE_SIGNATURE}" ]]; then
	echo "Error: Failed to generate probe signature with sign_update using provided private key." >&2
	exit 1
fi

if ! swift "${SCRIPT_DIR}/verify_signature.swift" "${PROBE_FILE}" "${PROBE_SIGNATURE}" "${SPARKLE_PUBLIC_KEY}" >/dev/null 2>&1; then
	echo "Error: Provided SPARKLE_PUBLIC_KEY does not match the key pair in SPARKLE_PRIVATE_KEY." >&2
	exit 1
fi

echo "==> Sparkle key pair validated successfully using official sign_update."

mkdir -p "${OUTPUT_DIR}"
ARCHIVE_PATH="${TEMP_DIR}/KonnectMac.xcarchive"
APP_EXPORT_DIR="${TEMP_DIR}/export"
APP_PATH="${APP_EXPORT_DIR}/KonnectMac.app"
FINAL_DMG_PATH="${OUTPUT_DIR}/KonnectMac-${VERSION}.dmg"
FINAL_ZIP_PATH="${OUTPUT_DIR}/KonnectMac-${VERSION}.zip"
FINAL_APPCAST_PATH="${OUTPUT_DIR}/appcast.xml"

echo "==> Building universal release archive with xcodebuild..."
xcodebuild archive \
	-project "${REPO_ROOT}/KonnectMac.xcodeproj" \
	-packageAuthorizationProvider netrc \
	-scheme "KonnectMac" \
	-configuration "Release" \
	-archivePath "${ARCHIVE_PATH}" \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGN_IDENTITY="" \
	CODE_SIGNING_REQUIRED=NO \
	CURRENT_PROJECT_VERSION="${VERSION}" \
	MARKETING_VERSION="${VERSION}" \
	SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY}" \
	SPARKLE_FEED_URL="${SPARKLE_FEED_URL}"

echo "==> Exporting application from archive..."
mkdir -p "${APP_EXPORT_DIR}"
ditto "${ARCHIVE_PATH}/Products/Applications/KonnectMac.app" "${APP_PATH}"

echo "==> Checking universal binary slices..."
ARCHS_FOUND=$(lipo -archs "${APP_PATH}/Contents/MacOS/KonnectMac")
echo "Architectures found: ${ARCHS_FOUND}"
if [[ "${ARCHS_FOUND}" != *"arm64"* ]] || [[ "${ARCHS_FOUND}" != *"x86_64"* ]]; then
	echo "Error: Universal binary does not contain both arm64 and x86_64 architectures: ${ARCHS_FOUND}" >&2
	exit 1
fi

# Verify Info.plist settings inside the exported app
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
PLIST_BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INFO_PLIST}" 2>/dev/null || true)
PLIST_SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}" 2>/dev/null || true)
PLIST_PUB_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${INFO_PLIST}" 2>/dev/null || true)
PLIST_FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${INFO_PLIST}" 2>/dev/null || true)

echo "Bundle Version: ${PLIST_BUNDLE_VERSION}"
echo "Short Version:  ${PLIST_SHORT_VERSION}"

if [[ "${PLIST_BUNDLE_VERSION}" != "${VERSION}" ]]; then
	echo "Error: CFBundleVersion '${PLIST_BUNDLE_VERSION}' does not match expected '${VERSION}'." >&2
	exit 1
fi

if [[ "${PLIST_SHORT_VERSION}" != "${VERSION}" ]]; then
	echo "Error: CFBundleShortVersionString '${PLIST_SHORT_VERSION}' does not match expected '${VERSION}'." >&2
	exit 1
fi

if [[ "${PLIST_PUB_KEY}" != "${SPARKLE_PUBLIC_KEY}" ]]; then
	echo "Error: Embedded SUPublicEDKey does not match SPARKLE_PUBLIC_KEY." >&2
	exit 1
fi

if [[ "${PLIST_FEED_URL}" != "${SPARKLE_FEED_URL}" ]]; then
	echo "Error: Embedded SUFeedURL '${PLIST_FEED_URL}' does not match expected '${SPARKLE_FEED_URL}'." >&2
	exit 1
fi

echo "==> Ad-hoc signing application..."
codesign --force --deep --sign - "${APP_PATH}"
echo "==> Verifying codesign..."
codesign --verify --deep --strict "${APP_PATH}"

# Package DMG with /Applications symlink in staging
echo "==> Creating DMG..."
DMG_STAGING_DIR="${TEMP_DIR}/dmg_staging"
mkdir -p "${DMG_STAGING_DIR}"
ditto "${APP_PATH}" "${DMG_STAGING_DIR}/KonnectMac.app"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

TEMP_DMG="${TEMP_DIR}/KonnectMac-${VERSION}.dmg"
hdiutil create \
	-volname "KonnectMac" \
	-srcfolder "${DMG_STAGING_DIR}" \
	-ov \
	-format UDZO \
	"${TEMP_DMG}"

# Package ZIP with symlinks preserved in staging
echo "==> Creating update ZIP..."
TEMP_ZIP="${TEMP_DIR}/KonnectMac-${VERSION}.zip"
(
	cd "${APP_EXPORT_DIR}"
	ditto -c -k --keepParent "KonnectMac.app" "${TEMP_ZIP}"
)

# Generate Sparkle appcast using official generate_appcast tool
echo "==> Generating Sparkle appcast..."
APPCAST_STAGING_DIR="${TEMP_DIR}/appcast_staging"
mkdir -p "${APPCAST_STAGING_DIR}"
cp "${TEMP_ZIP}" "${APPCAST_STAGING_DIR}/"

TEMP_APPCAST="${TEMP_DIR}/appcast.xml"
printf "%s" "${SPARKLE_PRIVATE_KEY}" | "${SPARKLE_BIN_DIR}/generate_appcast" \
	--ed-key-file - \
	--download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
	--maximum-deltas 0 \
	-o "${TEMP_APPCAST}" \
	"${APPCAST_STAGING_DIR}"

if [[ ! -f "${TEMP_APPCAST}" ]]; then
	echo "Error: Appcast file was not generated." >&2
	exit 1
fi

# Extract sparkle:edSignature from appcast.xml using xmllint and verify against ZIP and embedded public key
echo "==> Verifying update signature in appcast against ZIP and embedded public key..."
SPARKLE_SIGNATURE=$(/usr/bin/xmllint --xpath "string(//enclosure/@*[local-name()='edSignature'])" "${TEMP_APPCAST}" 2>/dev/null || true)

if [[ -z "${SPARKLE_SIGNATURE}" ]]; then
	echo "Error: Could not extract sparkle:edSignature from generated appcast using xmllint." >&2
	exit 1
fi

echo "Found signature: ${SPARKLE_SIGNATURE}"
swift "${SCRIPT_DIR}/verify_signature.swift" "${TEMP_ZIP}" "${SPARKLE_SIGNATURE}" "${PLIST_PUB_KEY}"

# Move built artifacts to final destination only after complete success
mv -f "${TEMP_DMG}" "${FINAL_DMG_PATH}"
mv -f "${TEMP_ZIP}" "${FINAL_ZIP_PATH}"
mv -f "${TEMP_APPCAST}" "${FINAL_APPCAST_PATH}"

echo "==> All release artifacts packaged and verified successfully:"
echo "  - DMG:     ${FINAL_DMG_PATH}"
echo "  - ZIP:     ${FINAL_ZIP_PATH}"
echo "  - Appcast: ${FINAL_APPCAST_PATH}"
