# Terigo Backend

This directory scaffolds the Terigo account, sharing, and collaboration backend
on Supabase.

## What it covers

- Strava-backed Terigo account bootstrap
- Persistent app sessions separate from the on-device Strava token
- Synced lists owned by accounts
- Link-based viewing, restricted invited-account viewing, link-based
  collaboration, and Strava-backed Terigo account-code collaboration
- Shared route snapshots, including downloadable GPX when the owner has already
  downloaded route details in the app
- Share-link HTML rendering so a shared list can open in the browser even before
  a dedicated web app exists

## Functions

- `account-bootstrap`
  - Verifies the access token against Strava's current-athlete endpoint
  - Upserts an account only from the server-verified Strava athlete
  - Issues a Terigo app-session token
- `delete-account`
  - Deletes the authenticated Terigo profile and all database records that
    cascade from it
  - Removes hosted shared GPX objects and invitations addressed to the deleted
    account code
- `start-contact-email-verification`
  - Deprecated compatibility endpoint
  - Returns `410 Gone` because Terigo now uses Strava-backed account codes
    instead of invite-email verification
- `confirm-contact-email`
  - Deprecated compatibility endpoint
  - Returns `410 Gone` because Terigo now uses Strava-backed account codes
    instead of invite-email verification
- `sync-list`
  - Upserts a list and its routes for the authenticated Terigo account
  - Enforces optimistic concurrency with `expectedRevision`
  - Applies delta updates for route membership and viewer/editor invites instead
    of destructive rewrites
  - Persists collaboration settings plus separate invited viewer and invited
    editor account-code grants
  - Uploads downloadable shared GPX assets into Supabase Storage for routes that
    were already downloaded in the app
- `shared-list`
  - Returns JSON for a live shared list
  - Returns basic HTML when opened in a browser
  - Requires an authenticated invited Terigo account for lists limited to
    specific viewers
  - Serves GPX downloads for routes that have a stored downloadable snapshot by
    issuing signed Supabase Storage URLs
- `account-lists`
  - Returns the authenticated account's owned, collaborative, and followed lists
  - Hydrates remote route memberships plus remote list revisions back onto a
    device after sign-in
- `follow-list`
  - Lets an authenticated account save or remove a shared list from their own
    library
- `strava-auth-broker`
  - Server-side exchange/refresh proxy for Strava OAuth so release builds do not
    ship the Strava client secret
  - Rejects client IDs and redirect URIs that do not match server configuration

## Storage and schema

- Shared downloadable route detail payloads live in the private
  `route-shared-gpx` Supabase Storage bucket.
- `shared_route_snapshots` stores storage metadata such as bucket, path, and
  file size instead of relying on large inline Postgres text payloads.
- Legacy `gpx_payload` rows are still readable as a compatibility fallback, but
  new writes should go through Storage.
- `route_lists.remote_revision` is the canonical backend revision counter for
  optimistic list sync.
- The live app/backend contract now treats Strava-backed Terigo account codes as
  the canonical private-sharing identity.
- The legacy email columns still exist in the database for backward
  compatibility, but new sharing flows should not depend on them.

## Share links

- The iOS app now generates HTTPS-first share links using
  `ROUTE_VAULT_SHARE_BASE_URL` when configured.
- The repo includes a deployable static share-site bundle under
  `RouteVaultShareSite/`:
  - `/.well-known/apple-app-site-association`
  - `/lists/shared/index.html`
- The app is configured for universal-link-ready handoff through
  `RouteVault.entitlements`, but a real HTTPS host must still serve the
  share-site assets before universal links will resolve on device.

## Required secrets

These should stay in ignored local env files or your deployment platform's
secret manager:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `STRAVA_CLIENT_ID`
- `STRAVA_CLIENT_SECRET`
- `STRAVA_REDIRECT_URI`

The iOS app only needs:

- `ROUTE_VAULT_SUPABASE_URL`
- `ROUTE_VAULT_SUPABASE_PUBLISHABLE_KEY`
- `ROUTE_VAULT_SHARE_BASE_URL`
- `ROUTE_VAULT_SHARE_LINK_HOST`

## Remaining deployment work

- Deploy `RouteVaultShareSite/` on `https://maxyaport.com` so it serves
  `/.well-known/apple-app-site-association`.
- Point `ROUTE_VAULT_SHARE_BASE_URL` and `ROUTE_VAULT_SHARE_LINK_HOST` at that
  deployed domain.
- Once hosted, rebuild the iOS app so the associated-domains entitlement matches
  the live share host.
- Add deployment-level rate limits and abuse alerts for account bootstrap, the
  Strava auth broker, feedback, and large list-sync requests.
