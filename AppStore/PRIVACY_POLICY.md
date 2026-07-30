# Terigo Privacy Policy

Terigo is an iPhone app for importing, organizing, downloading, sharing, and following routes.

## Data stored on your device

- Saved routes, route notes, tags, offline route files, and synced activity data on your device
- Strava access and refresh tokens in the iOS Keychain
- Your Terigo account session in the iOS Keychain

## Data stored by Terigo's hosted service

When you connect Strava and use account-backed features, Terigo stores:

- Your Strava athlete ID, display name, and profile image URL
- Terigo account sessions, stored as one-way token hashes
- Lists, sharing settings, invited account codes, followed lists, and route metadata you choose to sync
- Shared route geometry and GPX files you choose to make available through a shared list
- Feedback you choose to submit, linked to your Terigo account

Terigo's hosted service verifies every account directly with Strava. It does not store your Strava access token or refresh token after the verification request finishes.

## Network services

- When you connect Strava, the app exchanges authorization data with Strava and the configured Strava auth broker so it can import the routes and activities you approved.
- If you choose to upload an activity, the app sends the selected GPX or activity data back to Strava.
- When you inspect, share, follow, or download routes, the app may send coordinates or route metadata to providers that power those features, including Apple services for search and geocoding, Mapbox for map tiles, terrain, and offline regions, Supabase for account-backed list sharing, Open-Meteo for route-start weather forecasts, and Overpass or OpenStreetMap services for route surface classification.

## Location and notifications

- When route tracking is active and Continuous GPS is enabled, Terigo may continue receiving location updates while the app is in the background or the screen is locked so it can keep route progress current and alert you if you go off route.
- If you turn Continuous GPS off during route tracking, Terigo stops continuous background GPS and refreshes your position the next time you reopen the app.
- If you allow notifications, Terigo can send local off-route alerts during an active tracking session.

## What Terigo does not do

- No third-party advertising
- No sale of personal data
- No cross-app tracking

## Retention and deletion

- Terigo account sessions expire after 45 days.
- Account and sharing data is retained while your Terigo account exists.
- In Terigo, open Account settings and choose **Delete Terigo Account** to delete your hosted profile, account sessions, owned lists, sharing permissions, feedback, and stored shared-route files.
- Account deletion does not delete your Strava account. Routes stored only on your iPhone remain until you remove them or delete the app.
- Hosted-service logs and operational metadata may be retained by infrastructure providers only as needed for debugging, reliability, abuse prevention, and security monitoring, subject to those providers' retention and access controls.

## Support and privacy contact

- Support page: `https://maxyaport.com/terigo/support.html`
- Support email: `yaportmax@gmail.com`
- Issue tracker: `https://github.com/yaportmax/Terigo/issues`
