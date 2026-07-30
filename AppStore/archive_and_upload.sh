#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/StravaVaultClean.xcodeproj"
SCHEME="StravaVault"
ARCHIVE_PATH="$ROOT_DIR/.artifacts/StravaVault.xcarchive"
EXPORT_PATH="$ROOT_DIR/.artifacts/export"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/AppStore/ExportOptions-app-store.plist}"
EXPORT_OPTIONS_TEMPLATE="$ROOT_DIR/AppStore/ExportOptions-app-store.plist.template"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
API_KEY="${APPSTORE_API_KEY:-}"
API_ISSUER="${APPSTORE_API_ISSUER_ID:-}"
APPSTORE_TEAM_ID="${APPSTORE_TEAM_ID:-}"
APPSTORE_STRAVA_AUTH_BROKER_URL="${APPSTORE_STRAVA_AUTH_BROKER_URL:-}"
APPSTORE_MARKETING_VERSION="${APPSTORE_MARKETING_VERSION:-}"
APPSTORE_BUILD_NUMBER="${APPSTORE_BUILD_NUMBER:-}"

mkdir -p "$ROOT_DIR/.artifacts"

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  if [[ -z "$APPSTORE_TEAM_ID" ]]; then
    echo "Missing export options plist at $EXPORT_OPTIONS_PLIST"
    echo "Set APPSTORE_TEAM_ID so the script can generate one from the template, or create the plist manually."
    exit 1
  fi

  if [[ ! -f "$EXPORT_OPTIONS_TEMPLATE" ]]; then
    echo "Missing export options template at $EXPORT_OPTIONS_TEMPLATE"
    exit 1
  fi

  EXPORT_OPTIONS_PLIST="$ROOT_DIR/.artifacts/ExportOptions-app-store.generated.plist"
  sed "s/YOUR_TEAM_ID/$APPSTORE_TEAM_ID/g" "$EXPORT_OPTIONS_TEMPLATE" > "$EXPORT_OPTIONS_PLIST"
fi

"$ROOT_DIR/AppStore/preflight_release.sh"

BUILD_SETTING_OVERRIDES=()
if [[ -n "$APPSTORE_STRAVA_AUTH_BROKER_URL" ]]; then
  BUILD_SETTING_OVERRIDES+=("ROUTE_VAULT_STRAVA_AUTH_BROKER_URL=$APPSTORE_STRAVA_AUTH_BROKER_URL")
fi
if [[ -n "$APPSTORE_MARKETING_VERSION" ]]; then
  BUILD_SETTING_OVERRIDES+=("MARKETING_VERSION=$APPSTORE_MARKETING_VERSION")
fi
if [[ -n "$APPSTORE_BUILD_NUMBER" ]]; then
  BUILD_SETTING_OVERRIDES+=("CURRENT_PROJECT_VERSION=$APPSTORE_BUILD_NUMBER")
fi

echo "Archiving..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -allowProvisioningUpdates \
  "${BUILD_SETTING_OVERRIDES[@]}" \
  clean archive \
  -archivePath "$ARCHIVE_PATH"

echo "Exporting IPA..."
rm -rf "$EXPORT_PATH"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' | head -n 1)"
if [[ -z "$IPA_PATH" ]]; then
  echo "No IPA was exported."
  exit 1
fi

echo "IPA ready at $IPA_PATH"

if [[ -n "$API_KEY" && -n "$API_ISSUER" ]]; then
  echo "Uploading with App Store Connect API key..."
  xcrun altool --upload-app -f "$IPA_PATH" --type ios --apiKey "$API_KEY" --apiIssuer "$API_ISSUER"
elif [[ -n "$APPLE_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
  echo "Uploading with Apple ID and app-specific password..."
  xcrun altool --upload-app -f "$IPA_PATH" --type ios -u "$APPLE_ID" -p "$APPLE_APP_SPECIFIC_PASSWORD"
else
  echo "Skipping upload."
  echo "Set APPSTORE_API_KEY and APPSTORE_API_ISSUER_ID, or APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD, to upload."
fi
