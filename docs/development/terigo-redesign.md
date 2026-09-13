# Terigo redesign

This pass makes the existing route app easier to use and maintain. The SwiftData schema and saved route identifiers remain unchanged.

## Experience

- **Routes:** a searchable library with bounded route-trace thumbnails, removable filter chips, three saved density choices, and native sort and filter sheets.
- **Explore:** route starts and clusters, place search, a visible-area filter, full-screen maps, and an adaptive layout for portrait and landscape.
- **Lists:** native navigation, quick list creation, descriptions, per-list display settings, membership, sharing and collaboration, and offline downloads.
- **Activities:** searchable and sortable history, GPX import, Strava sync and upload, detailed effort analysis, and route extraction.
- **Route details:** map and elevation interaction, a readable summary, weather, sport and list editing, notes, GPX sharing, and persistent Start Activity and offline actions.
- **Local use:** GPX routes and activities are available without signing into Strava. Existing saved routes remain accessible when a connection expires.

The color palette follows the system appearance by default. Existing explicit display preferences are retained. Unconfigured builds use Apple Maps; configured builds retain Mapbox styles, terrain, and offline regions. GPX downloads work independently of offline map tiles.

## Reliability and maintenance

The route-library file is separated into focused files for controls, filters, lists, map presentation, map rendering, offline downloads, account sheets, and Spotlight. Unreferenced view implementations and duplicated range controls are removed.

Route thumbnails render a bounded number of points. Search and remote-list sync debounce work and respect cancellation. Save errors remain visible. Route deletion uses the shared library model, preserves Strava deletion tombstones, and captures offline file locations before SwiftData invalidates the record. Library-open errors offer recovery without silently creating an empty replacement store.

Numeric range input must parse in full and respects the user's locale. Map-area filtering handles routes across the date line. Cancelled or timed-out Mapbox downloads resume their waiting task and cancel the SDK request. Concurrent Strava refreshes and GPX requests share one task; the bounded GPX cache is partitioned by authorization. Missing permissions or app configuration keep saved credentials intact. A review access code cannot replace an existing library, and exiting demo mode explicitly confirms deletion of its data.

## Features retained

| Area | Preserved behavior |
| --- | --- |
| Strava | OAuth, refresh tokens in Keychain, route and activity sync, private-access handling, uploads, reconnect and disconnect |
| Import and export | GPX routes and activities, route extraction from an activity, GPX sharing, data export |
| Organization | Multi-criterion sort, sport/movement/surface/range/start/list/offline filters, notes, lists and membership |
| Maps | Route traces, clustered starts, place search, map styles, perspective, full-screen maps, elevation selection |
| Offline | GPX, configured Mapbox map styles and terrain, batch downloads, shared-bundle accounting and removal |
| Tracking | GPS route progress, breadcrumbs, elevation, continuous GPS, battery controls and off-route notifications |
| Sharing | Hosted account profiles, account codes, list visibility, collaborators, viewers, following and incoming links |
| Recovery | Deleted Strava route restoration, local data access after disconnect, save-error feedback and library-open retry |

## Validation

The `iOS simulator validation` workflow builds the real `StravaVault` scheme on a GitHub macOS runner. It runs unit tests and a new UI suite with synthetic routes and activities, captures native screenshots through XCTest, and exports the evidence with its source commit.

The visual tour covers light and dark appearance, the four destinations, route and activity details, filters, sorting, offline management, list creation and deletion, tracking, welcome and local use, account, feedback, export, storage recovery, large text, and landscape. Results and remaining limitations are recorded with the pull request after inspecting the exported images.

Simulator fixtures do not verify live Strava credentials, hosted sharing permissions, physical GPS accuracy, background battery use, App Store signing, or real offline Mapbox tile downloads. Those require the configured services or a physical device. This change does not deploy backend functions, migrate the database, or publish an App Store build.

## Strava connection check — 13 September 2026

The public client ID is configured as `168528`; no developer secret or test token is bundled. Normal use still goes through Connect with Strava, browser consent, callback-state verification, server token exchange, and Keychain storage. A working auth broker must be configured for release builds. The documented Supabase host returned public DNS status `NXDOMAIN` on 13 September 2026 (a Strava hostname control resolved successfully). Restore a live project and configure its broker URL before installing a connected build. End-to-end production login remains unverified.

An authorized, temporary developer token successfully read the athlete profile, route list, route detail, and a valid GPX export. Activity access returned Strava's `activity:read_permission` fault because that token has only `read` scope. The client now distinguishes this permission fault from an invalid session and preserves access to already authorized features. All simulator fixtures remain synthetic.

Route actions are available from an explicit ellipsis menu and a long press. This replaces custom swipe handling that interfered with vertical scrolling, while preserving offline downloads/removal, directions to the start, list membership and creation, Strava links, and deletion.
