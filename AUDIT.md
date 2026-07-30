# Terigo Audit

Audit date: 2026-07-30

## Scope

This review covered the shipping iOS target, local credential handling, Strava OAuth, Supabase account and sharing functions, database access controls, storage, privacy declarations, release configuration, tests, accessibility markers, dependency pinning, repository history, and open-source release hygiene.

The primary code review ran on Windows. GitHub Actions then completed a clean macOS build of the shared `StravaVault` scheme and extended CodeQL analysis of Swift, Actions, JavaScript/TypeScript, and Python. A unit test run, UI test run, Release archive preflight, and live backend integration test remain required before an App Store release.

## Verification completed

- The public-release validator, script syntax checks, Deno formatting and type checks, and full-history gitleaks scan pass.
- GitHub's dependency review, Dependabot advisory scan, secret scanning, and push protection report no open alerts at audit completion.
- The macOS workflow resolves the locked Swift packages and builds the iOS app through the shared scheme with signing disabled.
- Extended CodeQL analysis passes for Swift, Actions, JavaScript/TypeScript, and Python with no open findings at audit completion.

## Release blockers fixed

- Replaced the private repository's credential-bearing historical graph with a clean public release tree.
- Removed local environment files, developer signing settings, App Store artifacts, local backend state, Xcode user data, and uncompiled legacy implementations from the public tree.
- Removed a committed Mapbox public token and Strava client ID from the Xcode project. Contributors now supply their own values through ignored configuration.
- Fixed backend account bootstrap so the server asks Strava which athlete owns the access token instead of trusting a client-supplied athlete ID.
- Brought the local backend into parity with the hosted identity and account-deletion flows so local testing no longer accepts a client-asserted athlete.
- Fixed stale follower access so a list that changes from link-visible to private is no longer returned to followers.
- Added in-app account deletion and backend deletion of the hosted profile, sessions, owned lists, invitations, feedback, and shared GPX objects.
- Declared collected account, fitness, precise-location, user-content, support, and user-ID data in the app privacy manifest.

## Security and privacy improvements

- Keychain entries now use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Production service URLs require HTTPS. Debug builds allow plain HTTP only for local development hosts.
- Strava broker requests are bound to the configured client ID and redirect URI and validate token or code size.
- Decode diagnostics no longer print response bodies that may contain athlete data.
- API responses opt out of caching and include referrer and content-type protections.
- Shared-list HTML uses a restrictive Content Security Policy and denies framing.
- Shared GPX filenames are sanitized before use in response headers.
- Feedback and list-sync inputs now have method, type, count, and size limits.
- Added aggregate sync-request limits and outbound Strava timeouts to reduce memory and connection-exhaustion abuse.
- Normalized Supabase relationship results so single-object and array response shapes are both handled safely.
- Privacy and support documents now explain hosted data, retention, deletion, and the difference between Terigo account deletion and Strava account deletion.

## Open-source readiness improvements

- Added an MIT license, contribution guide, security policy, code of conduct, validation script, issue templates, dependency updates, and automated public-release checks.
- Documented the shipping source layout, configuration model, backend secrets, privacy boundaries, and release preflight.
- Kept the Swift package lockfile so Mapbox dependency versions are reproducible.
- Restored the standard Xcode workspace metadata so package resources and the shared scheme resolve through one build directory on clean machines and CI.
- Replaced CodeQL's target-based Swift autobuild with a pinned advanced workflow that performs a bounded manual scheme build before analysis.

## Remaining priorities

### P1 before the next production release

- Run the complete unit and UI test matrix on macOS, including a Release archive with no Strava client secret.
- Deploy the updated Supabase functions, including `account-bootstrap`, `account-lists`, `delete-account`, `shared-list`, `strava-auth-broker`, `submit-feedback`, and `sync-list`.
- Add integration tests for account bootstrap, list visibility transitions, account deletion, storage cleanup, and expired sessions.
- Add rate limiting and abuse monitoring for the public Strava broker, account bootstrap, feedback, and large sync requests.
- Decide and enforce one Swift language mode: several shipping and test target settings still override `Shared.xcconfig` 6.0 with Swift 5.0.

### P2 product and maintainability

- Expand unit coverage beyond the current activity-model tests, especially route filtering, GPX parsing, sync conflict handling, URL validation, and account state transitions.
- Add VoiceOver and Dynamic Type UI tests for the route library, tracking, sharing, and account deletion flows.
- Separate link-view and link-edit bearer capabilities so view-only links never double as edit authorization.
- Add share-token rotation and an in-app list access audit.
- Add explicit backend retention jobs for expired sessions and old feedback.
- Replace broad cross-origin API access with a deployment-specific origin allowlist if browser clients are added.

### P3 cleanup

- Reduce large SwiftUI and model files into smaller feature modules.
- Add localized strings and a documented localization workflow.
- Add deterministic screenshot fixtures that never depend on real athlete data.
