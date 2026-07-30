# Contributing to Terigo

Thanks for helping improve Terigo.

## Before opening an issue

- Search existing issues first.
- Do not include access tokens, route files, exact home locations, private Strava data, screenshots containing personal data, or Apple signing material.
- For a security vulnerability, follow `SECURITY.md` instead of filing a public issue.

## Development setup

1. Follow the local setup in `README.md`.
2. Keep all credentials in the ignored local configuration files.
3. Make focused changes against the `main` branch.
4. Add or update tests for behavior changes.
5. Run `python Scripts/validate_public_release.py`.
6. On macOS, build and test the `StravaVault` scheme before requesting review.

## Pull requests

A pull request should explain:

- What changed and why
- Any user-visible or data-handling impact
- How it was tested
- Whether backend functions or database migrations must be deployed
- Any App Store privacy or permission changes

Keep unrelated changes in separate pull requests. New network services, collected data types, permissions, and dependencies require an accompanying privacy and security review.

## Style

- Prefer clear Swift and TypeScript over clever abstractions.
- Keep secrets and environment-specific identifiers out of source.
- Treat route geometry, athlete identity, location, and shared-list tokens as private data.
- Preserve accessibility labels for icon-only controls and add them to new interactive elements.
