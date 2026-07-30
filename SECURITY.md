# Security Policy

## Supported version

Security fixes are applied to the latest code on `main`.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting flow from the repository's **Security** tab. Do not open a public issue for a suspected vulnerability.

Include:

- A concise description and impact
- Reproduction steps or a proof of concept
- Affected app, backend function, or data flow
- Any suggested mitigation

Do not include real access tokens, Strava authorization codes, private routes, precise personal locations, Apple credentials, or other people's data. Use synthetic test data.

You should receive an acknowledgment within 3 business days. Valid reports will be investigated privately, fixed on a private branch when needed, and disclosed after affected deployments and credentials are secured.

## Security boundaries

- Release builds must use the server-side Strava auth broker and must not ship a Strava client secret.
- Supabase service-role keys, Mapbox secret tokens, Apple signing material, and App Store Connect credentials are server-side or local-only secrets.
- Supabase publishable keys and Mapbox public tokens are client identifiers. They should still be scoped and restricted in the provider dashboard.
- Terigo account sessions belong in the iOS Keychain and are stored only as hashes by the backend.
- Shared-list tokens are bearer capabilities. Treat a share link according to the access level chosen for that list.
