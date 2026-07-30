# Terigo App Store Readiness

Use `StravaVaultClean.xcodeproj` and the `StravaVault` scheme for every release build, preflight, archive, and upload step. The other legacy Xcode projects in this repo are not the shipping target.

The repo can enforce most submission safety checks, but App Store Connect still needs a few account-level and hosted-service values that cannot be completed from Xcode alone.

## Current Account Blockers

- A Personal Team can sign local builds, but it cannot publish an App Store release.
- Upload from the command line requires either an App Store Connect API key or an Apple ID with an app-specific password.
- If automatic signing reports that the team has no devices for provisioning, add at least one device to the Apple Developer account or switch to a paid team that supports App Store distribution.

## Release-Side Requirements

1. Deploy the Strava auth broker, preferably from `supabase/functions/strava-auth-broker/` on the Supabase project host. The legacy worker template remains at `AppStore/strava-auth-broker.js`.
2. Set `APPSTORE_STRAVA_AUTH_BROKER_URL` when running the archive helper, or set the release build setting `ROUTE_VAULT_STRAVA_AUTH_BROKER_URL` before archiving in Xcode. Intended production endpoint: `https://jpxinpbqjovazsxrhdkn.supabase.co/functions/v1/strava-auth-broker`.
3. Keep `ROUTE_VAULT_STRAVA_CLIENT_SECRET` empty for the release build.
4. In the Strava developer portal, set the app callback URI to `routevault://localhost/oauth-callback`.
5. Change the Strava developer portal callback domain to the real production host you use for the auth broker. If you deploy the included Supabase function, that host is `jpxinpbqjovazsxrhdkn.supabase.co`.
6. Use the published Terigo support and privacy pages on `https://maxyaport.com/terigo/` in App Store Connect.
7. Deploy and verify the `delete-account` Edge Function, then test the in-app deletion flow against a disposable account.
7. Run `AppStore/preflight_release.sh` before every archive. The archive helper runs it automatically.

## App Store Connect Checklist

- Before the first TestFlight upload, manually create the App Store Connect app record in the web UI. Apple upload tools reject the IPA until a matching app exists for bundle ID `com.myaport.RouteVault`.
- App name: `Terigo`
- Bundle ID: `com.myaport.RouteVault`
- SKU suggestion: `terigo-ios`
- Subtitle suggestion: `Organize Strava routes`
- Category suggestion: `Sports`
- Device support: `iPhone only`
- Support URL: `https://maxyaport.com/terigo/support.html`
- Privacy Policy URL: `https://maxyaport.com/terigo/privacy.html`
- Screenshots: upload 1 to 10 screenshots for iPhone, preferably 6.9-inch
- Export compliance: answer `No` for non-exempt encryption if the shipping build only uses Apple-standard exempt encryption and the Info.plist key remains `ITSAppUsesNonExemptEncryption = NO`
- App privacy: re-answer the App Store Connect privacy questionnaire against the current app, including optional Continuous GPS background route tracking vs reopen-refresh tracking when Continuous GPS is off, lock-screen off-route notifications, route-detail weather, activity sync/upload, shared-list collaboration, and the network services used for Strava, Mapbox, Apple geocoding/search, Supabase, Open-Meteo weather requests, and Overpass requests
- Upload path: use `AppStore/archive_and_upload.sh` after configuring a valid distribution team, upload credentials, and broker URL

## Local Asset Pack

The repo now includes a local submission asset pack under `AppStore/SubmissionAssets/`.

- Store metadata: `AppStore/SubmissionAssets/metadata/AppStoreConnectMetadata.md`
- Store metadata JSON: `AppStore/SubmissionAssets/metadata/AppStoreConnectMetadata.json`
- Review notes: `AppStore/SubmissionAssets/review/AppReviewNotes.md`
- Privacy answers draft: `AppStore/SubmissionAssets/privacy/AppStorePrivacyQuestionnaire.md`
- Screenshot templates: `AppStore/SubmissionAssets/screenshots/`
- Final 6.9-inch screenshots: `AppStore/SubmissionAssets/screenshots/final_6_9_inch/`
- Hosted support/privacy page source: `AppStore/Site/`

Generate or refresh the screenshot templates with:

- `Scripts/generate_app_store_assets.py`
- `Scripts/compose_app_store_screenshot.py` can place a real capture into a template once you have device or simulator screenshots.
- `Scripts/capture_app_store_screenshots.py` refreshes the current four-shot App Store set from the checked-in Terigo post captures, or from the booted simulator if those source overrides are replaced.

## Suggested Metadata

### Promotional Text
Bring your Strava routes into a cleaner library built for search, filters, lists, map browsing, and route-aware tracking.

### Description
Terigo is a route library for Strava users who have outgrown a basic saved-routes list.

Import your routes from Strava, then organize them with lists, tags, stackable filters, flexible sorting, and geo-aware search. Find routes by sport, movement type, surface, distance, elevation gain, difficulty, or starting area.

Browse route clusters on a map, compare nearby options, and open rich 2D or 3D map views with satellite, standard, and hybrid styles. Control what you keep on device, from route metadata to GPX, altitude, and map tiles.

When it is time to move, follow the line with clear route-aware tracking, an elevation profile, off-route visibility, and controls for GPS behavior.

Built for runners, cyclists, hikers, and route-heavy athletes, Terigo makes it easier to find the right route when your library has grown into the hundreds.

### Keywords
routes,strava,gpx,route library,cycling,running,hiking,trail routes,route tracker,map browse

## Manual Review Notes

- Do not use Strava’s logo as the app icon.
- Do not list the app name as `Strava Vault` in App Store Connect.
- Verify the release build can complete OAuth through the deployed broker before submitting to App Review.
- Verify the support page and privacy policy are live on public HTTPS URLs before creating the App Store Connect version.
- If you need a fresh export-options plist, set `APPSTORE_TEAM_ID` and let `AppStore/archive_and_upload.sh` generate one into `.artifacts/`.
