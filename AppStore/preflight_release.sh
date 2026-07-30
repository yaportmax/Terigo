#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/StravaVaultClean.xcodeproj"
SCHEME="StravaVault"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/AppStore/ExportOptions-app-store.plist}"
APPSTORE_TEAM_ID="${APPSTORE_TEAM_ID:-}"
APPSTORE_STRAVA_AUTH_BROKER_URL="${APPSTORE_STRAVA_AUTH_BROKER_URL:-}"
APPSTORE_MARKETING_VERSION="${APPSTORE_MARKETING_VERSION:-}"
APPSTORE_BUILD_NUMBER="${APPSTORE_BUILD_NUMBER:-}"

typeset -a failures
typeset -a warnings

add_failure() {
  failures+=("$1")
}

add_warning() {
  warnings+=("$1")
}

resolved_setting() {
  local key="$1"
  awk -F ' = ' -v key="$key" '$1 ~ "[[:space:]]" key "$" { print $2; exit }' <<<"$BUILD_SETTINGS"
}

host_from_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
}

host_resolves() {
  local host="$1"
  local cache_result

  if [[ -z "$host" ]]; then
    return 1
  fi

  cache_result="$(dscacheutil -q host -a name "$host" 2>/dev/null || true)"
  if [[ -n "$cache_result" ]]; then
    return 0
  fi

  dig +short "$host" 2>/dev/null | rg -q "."
}

assert_resolvable_url() {
  local label="$1"
  local url="$2"
  local host

  host="$(host_from_url "$url")"
  if [[ -z "$host" ]]; then
    add_failure "$label has no hostname. Current value: $url"
    return
  fi

  if ! host_resolves "$host"; then
    add_failure "$label host '$host' does not resolve in DNS. Check that the backend project is active before archiving."
  fi
}

if ! python3 "$ROOT_DIR/Scripts/validate_public_release.py"; then
  add_failure "Public repository safety validation failed."
fi

if [[ ! -d "$PROJECT" ]]; then
  add_failure "Missing shipping project at $PROJECT"
fi

if [[ ! -f "$ROOT_DIR/StravaVault/PrivacyInfo.xcprivacy" ]]; then
  add_failure "Missing privacy manifest at $ROOT_DIR/StravaVault/PrivacyInfo.xcprivacy"
fi

if [[ ! -f "$ROOT_DIR/StravaVault/Assets.xcassets/AppIcon.appiconset/AppIcon-ios-marketing-1024x1024-1x.png" ]]; then
  add_failure "Missing 1024x1024 App Store icon asset."
fi

if ! rg -q "PrivacyInfo.xcprivacy in Resources" "$ROOT_DIR/StravaVaultClean.xcodeproj/project.pbxproj"; then
  add_failure "The shipping project does not include the privacy manifest in app resources."
fi

if rg -q "support@example.com|https://example.com" "$ROOT_DIR/AppStore/SUPPORT.md"; then
  add_failure "AppStore/SUPPORT.md still contains placeholder contact details."
fi

if rg -q "Before publishing this policy|remaining placeholders|exact production host name|retention and logging policy" "$ROOT_DIR/AppStore/PRIVACY_POLICY.md"; then
  add_failure "AppStore/PRIVACY_POLICY.md still contains unfinished publication placeholders."
fi

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  if [[ -z "$APPSTORE_TEAM_ID" ]]; then
    add_failure "Missing AppStore/ExportOptions-app-store.plist and APPSTORE_TEAM_ID is not set."
  fi
elif rg -q "YOUR_TEAM_ID" "$EXPORT_OPTIONS_PLIST"; then
  add_failure "AppStore export options still contains the YOUR_TEAM_ID placeholder."
fi

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=iOS"
)

if [[ -n "$APPSTORE_STRAVA_AUTH_BROKER_URL" ]]; then
  BUILD_ARGS+=("ROUTE_VAULT_STRAVA_AUTH_BROKER_URL=$APPSTORE_STRAVA_AUTH_BROKER_URL")
fi

if [[ -n "$APPSTORE_MARKETING_VERSION" ]]; then
  BUILD_ARGS+=("MARKETING_VERSION=$APPSTORE_MARKETING_VERSION")
fi

if [[ -n "$APPSTORE_BUILD_NUMBER" ]]; then
  BUILD_ARGS+=("CURRENT_PROJECT_VERSION=$APPSTORE_BUILD_NUMBER")
fi

BUILD_SETTINGS="$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null || true)"
if [[ -z "$BUILD_SETTINGS" ]]; then
  add_failure "Failed to read release build settings from $PROJECT."
fi

TARGET_FAMILY="$(resolved_setting TARGETED_DEVICE_FAMILY)"
if [[ "$TARGET_FAMILY" != "1" ]]; then
  add_failure "The shipping target must be iPhone-only for App Store submission; TARGETED_DEVICE_FAMILY resolved to '$TARGET_FAMILY'."
fi

BUNDLE_ID="$(resolved_setting PRODUCT_BUNDLE_IDENTIFIER)"
if [[ -z "$BUNDLE_ID" || "$BUNDLE_ID" == *routearchive* ]]; then
  add_failure "Unexpected release bundle identifier '$BUNDLE_ID'."
fi

CLIENT_ID="$(resolved_setting ROUTE_VAULT_STRAVA_CLIENT_ID)"
if [[ -z "$CLIENT_ID" || ! "$CLIENT_ID" =~ ^[0-9]+$ ]]; then
  add_failure "Release Strava client ID is missing or invalid."
fi

BROKER_URL="$(resolved_setting ROUTE_VAULT_STRAVA_AUTH_BROKER_URL)"
if [[ -z "$BROKER_URL" ]]; then
  add_failure "Release Strava auth broker URL is empty. Set APPSTORE_STRAVA_AUTH_BROKER_URL or the release build setting before archiving."
elif [[ "$BROKER_URL" != https://* ]]; then
  add_failure "Release Strava auth broker URL must use HTTPS. Current value: $BROKER_URL"
else
  assert_resolvable_url "Release Strava auth broker URL" "$BROKER_URL"
fi

SUPABASE_URL="$(resolved_setting ROUTE_VAULT_SUPABASE_URL)"
if [[ -z "$SUPABASE_URL" ]]; then
  add_failure "Release Supabase URL is empty. Set ROUTE_VAULT_SUPABASE_URL before archiving."
elif [[ "$SUPABASE_URL" != https://* ]]; then
  add_failure "Release Supabase URL must use HTTPS. Current value: $SUPABASE_URL"
else
  assert_resolvable_url "Release Supabase URL" "$SUPABASE_URL"
fi

CLIENT_SECRET="$(resolved_setting ROUTE_VAULT_STRAVA_CLIENT_SECRET)"
if [[ -n "$CLIENT_SECRET" ]]; then
  add_failure "Release Strava client secret must be empty; use the broker instead."
fi

MAPBOX_TOKEN="$(resolved_setting ROUTE_VAULT_MAPBOX_PUBLIC_TOKEN)"
if [[ -z "$MAPBOX_TOKEN" ]]; then
  add_failure "Release Mapbox public token is missing."
fi

MARKETING_VERSION="$(resolved_setting MARKETING_VERSION)"
BUILD_NUMBER="$(resolved_setting CURRENT_PROJECT_VERSION)"
if [[ "$MARKETING_VERSION" == "1.0" && "$BUILD_NUMBER" == "1" && -z "$APPSTORE_BUILD_NUMBER" && -z "$APPSTORE_MARKETING_VERSION" ]]; then
  add_warning "Release version/build are still 1.0 (1). Increment them before any upload after the first submission."
fi

if (( ${#warnings[@]} > 0 )); then
  echo "Warnings:"
  for warning in "${warnings[@]}"; do
    echo "  - $warning"
  done
fi

if (( ${#failures[@]} > 0 )); then
  echo "App Store preflight failed:"
  for failure in "${failures[@]}"; do
    echo "  - $failure"
  done
  exit 1
fi

echo "App Store preflight passed."
echo "  Project: $PROJECT"
echo "  Scheme: $SCHEME"
echo "  Bundle ID: $BUNDLE_ID"
echo "  Version: $MARKETING_VERSION ($BUILD_NUMBER)"
echo "  Broker URL: $BROKER_URL"
