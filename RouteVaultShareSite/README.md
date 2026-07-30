# Terigo Share Site

This static site is the deployable companion for Terigo universal-link sharing.

## What it provides

- `/.well-known/apple-app-site-association` for iOS universal links
- `/lists/shared?token=...` browser fallback rendering for shared Terigo lists

## Required hosting behavior

- Serve this directory over `https`
- Serve `/.well-known/apple-app-site-association` with no redirect
- Point the iOS associated-domains entitlement host at the same domain
- Set `ROUTE_VAULT_SHARE_BASE_URL` in the iOS app to that same `https://...` origin

Current production host: `https://maxyaport.com`

## Backend dependency

The included page fetches shared-list JSON from the current Supabase function endpoint:

- `https://jpxinpbqjovazsxrhdkn.supabase.co/functions/v1/shared-list`

If that changes, update `lists/shared/index.html`.
