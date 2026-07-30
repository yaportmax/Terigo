# Terigo

Terigo is an open-source iPhone app for importing, organizing, saving offline, sharing, and following routes from one map-first library.

[![License: MIT](https://img.shields.io/badge/License-MIT-orange.svg)](LICENSE)

## Features

- Strava OAuth with token refresh and Keychain-backed local sessions
- Route and activity import through the official Strava APIs
- Offline route library, map detail, GPX import, and offline map bundles
- Background-capable route tracking with local off-route alerts
- Search and filters across route names, notes, tags, start areas, sport, surface, distance, and climb
- Route-start weather, activity sync and upload, coverage views, Spotlight indexing, and data export
- Supabase-backed Terigo accounts, shared lists, collaboration, following, and cross-device list sync
- Public share pages and universal-link-ready handoff

## Repository layout

| Path | Purpose |
| --- | --- |
| `StravaVault/` | Shipping SwiftUI app source |
| `StravaVaultClean.xcodeproj/` | Shipping Xcode project and shared scheme |
| `StravaVaultCleanTests/` | Unit tests |
| `StravaVaultCleanUITests/` | UI and launch tests |
| `Configuration/` | Checked-in defaults and local configuration templates |
| `supabase/` | Database migrations and Edge Functions |
| `RouteVaultShareSite/` | Static universal-link and shared-list handoff assets |
| `AppStore/` | Release checks, public policy source, and broker template |
| `docs/` | GitHub Pages support and privacy pages |
| `Scripts/` | Local verification and release helpers |

## Requirements

- macOS with Xcode 26 or a newer compatible Xcode release
- iOS 17 or newer
- A Strava developer application
- A Mapbox public token
- Optional: a Supabase project for accounts and sharing

## Local setup

1. Clone the repository.
2. Copy `Configuration/Secrets.template.xcconfig` to `Configuration/Secrets.xcconfig`.
3. Add your Strava client ID, development-only Strava client secret, and Mapbox public token.
4. If you want account and sharing features, add your Supabase URL, publishable key, Functions URL, and share URL.
5. Copy `Configuration/DeveloperSigning.template.xcconfig` to `Configuration/DeveloperSigning.xcconfig` and add your Apple Developer Team ID.
6. Open `StravaVaultClean.xcodeproj` and run the `StravaVault` scheme.

Both local configuration files are ignored by git.

Set the Strava redirect URI to:

```text
routevault://localhost/oauth-callback
```

## Backend setup

The Supabase backend verifies the current athlete directly with Strava before issuing a Terigo account session. Terigo account tokens are stored only as SHA-256 hashes. Shared GPX files use a private Storage bucket and short-lived signed download URLs.

Apply the migrations in `supabase/migrations/`, then deploy the functions in `supabase/functions/`. Configure these server-side secrets:

```text
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
STRAVA_CLIENT_ID
STRAVA_CLIENT_SECRET
STRAVA_REDIRECT_URI
```

The iOS app must receive only the Supabase publishable key. Never put the service-role key, Strava client secret, Mapbox secret token, Apple signing credentials, or App Store Connect credentials in the app bundle or repository.

See `supabase/README.md` for the function contract and deployment notes.

## Release safety

Release builds must use the server-side Strava auth broker and must not contain a Strava client secret. Before archiving:

```shell
AppStore/preflight_release.sh
```

The preflight checks the shipping project, privacy manifest, release URLs, bundle settings, map token, and the absence of a bundled Strava client secret. `AppStore/archive_and_upload.sh` runs the same preflight before archiving.

The repository is also checked for forbidden credential files, hardcoded private tokens, invalid property lists, and malformed backend source through `Scripts/validate_public_release.py`.

## Privacy

Terigo keeps route and activity data on the device unless the user chooses an action that requires a network service, such as sharing a list, requesting map or weather data, or uploading an activity. Account deletion is available in the app and removes hosted account and sharing data.

See [the privacy policy](docs/privacy.html) and [security policy](SECURITY.md).

## Contributing

Bug reports and focused pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

Terigo is available under the [MIT License](LICENSE). Third-party services and dependencies remain subject to their own terms and licenses.
