import XCTest
@testable import StravaVault

@MainActor
final class ActivitiesModelTests: XCTestCase {
    func testBackendCannotFindHostMessageNamesConfiguredHost() {
        let error = RouteVaultBackendService.BackendError.transport(
            URLError(.cannotFindHost),
            URL(string: "https://missing-project.supabase.co/functions/v1/account-bootstrap")
        )

        XCTAssertEqual(
            error.errorDescription,
            "Terigo's hosted backend could not be found at missing-project.supabase.co. Check that the configured Supabase project is active and rebuild with the live backend URL."
        )
    }

    func testStravaBrokerCannotFindHostMessageNamesConfiguredHost() {
        let error = StravaAPIService.APIError.transport(
            URLError(.cannotFindHost),
            URL(string: "https://missing-project.supabase.co/functions/v1/strava-auth-broker/exchange")
        )

        XCTAssertEqual(
            error.errorDescription,
            "Terigo's Strava auth broker could not be found at missing-project.supabase.co. Check that the configured Supabase project is active and rebuild with the live broker URL."
        )
    }

    func testRouteLibrarySportFiltersOrderByMostCommonRouteType() {
        let model = RouteLibraryModel()
        let routes = [
            makeRoute(id: 1, typeCode: 2, subTypeCode: nil),
            makeRoute(id: 2, typeCode: 2, subTypeCode: nil),
            makeRoute(id: 3, typeCode: 2, subTypeCode: 4),
            makeRoute(id: 4, typeCode: 1, subTypeCode: nil),
            makeRoute(id: 5, typeCode: 2, subTypeCode: nil)
        ]

        let orderedSports = model.orderedSportFilters(from: routes)

        XCTAssertEqual(orderedSports.prefix(4), [.all, .run, .ride, .trailRun])
    }

    func testAnalyticsBlockingStateShowsPreparingWithoutZeroProgressBeforeIndexingStarts() {
        let model = ActivitiesModel()
        model.installTestSession(makeStubSession())

        let state = model.analyticsBlockingState(for: [makePendingStravaActivity()])

        XCTAssertEqual(state?.title, "Preparing Workout Sync")
        XCTAssertNil(state?.completedCount)
        XCTAssertNil(state?.totalCount)
        XCTAssertNil(state?.progressLabel)
    }

    func testAnalyticsReadinessSignatureIgnoresProgressCountersUntilIndexingStarts() {
        let model = ActivitiesModel()
        model.installTestSession(makeStubSession())
        let activities = [makePendingStravaActivity()]

        let initialSignature = model.analyticsReadinessSignature(for: activities)
        model.indexedActivityCount = 5
        model.totalActivityIndexCount = 17
        let preIndexingProgressSignature = model.analyticsReadinessSignature(for: activities)

        XCTAssertEqual(initialSignature, preIndexingProgressSignature)

        model.isIndexingDetails = true
        let activeIndexingSignature = model.analyticsReadinessSignature(for: activities)

        XCTAssertNotEqual(preIndexingProgressSignature, activeIndexingSignature)
    }

    func testAnalyticsBlockingStateShowsProgressOnlyWhileIndexingIsActive() {
        let model = ActivitiesModel()
        model.installTestSession(makeStubSession())
        model.isIndexingDetails = true
        model.indexedActivityCount = 3
        model.totalActivityIndexCount = 9

        let state = model.analyticsBlockingState(for: [makePendingStravaActivity()])

        XCTAssertEqual(state?.title, "Syncing Workout Details")
        XCTAssertEqual(state?.progressLabel, "3 of 9 workouts ready")
    }

    func testAnalyticsBlockingStateShowsPausedMessageWhenRateLimited() {
        let model = ActivitiesModel()
        model.installTestSession(makeStubSession())
        model.activityDetailRateLimitResetAt = Date().addingTimeInterval(600)

        let state = model.analyticsBlockingState(for: [makePendingStravaActivity()])

        XCTAssertEqual(state?.title, "Workout Sync Paused")
        XCTAssertNil(state?.progressLabel)
        XCTAssertNil(state?.completedCount)
    }

    func testOfflineCoverageBoundsContainSmallerArea() {
        let larger = RouteOfflineMapMetadata.CoverageBounds(
            minimumLatitude: 37.70,
            maximumLatitude: 37.82,
            minimumLongitude: -122.55,
            maximumLongitude: -122.35
        )
        let smaller = RouteOfflineMapMetadata.CoverageBounds(
            minimumLatitude: 37.74,
            maximumLatitude: 37.78,
            minimumLongitude: -122.49,
            maximumLongitude: -122.41
        )

        XCTAssertTrue(larger.contains(smaller))
        XCTAssertFalse(smaller.contains(larger))
    }

    func testTotalOfflineBytesCountsSharedTileRegionOnlyOnce() throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let routeOne = makeRoute(id: 101, typeCode: 2, subTypeCode: nil)
        let routeTwo = makeRoute(id: 102, typeCode: 2, subTypeCode: nil)
        let sharedTileRegionID = "shared-region-1"

        try writeOfflineBundle(
            for: routeOne,
            baseDirectory: baseDirectory,
            gpxName: "route-one.gpx",
            metadataName: "route-one-offline-mapbox.json",
            tileRegionID: sharedTileRegionID,
            approximateByteCount: 8_000
        )
        try writeOfflineBundle(
            for: routeTwo,
            baseDirectory: baseDirectory,
            gpxName: "route-two.gpx",
            metadataName: "route-two-offline-mapbox.json",
            tileRegionID: sharedTileRegionID,
            approximateByteCount: 8_000
        )

        let routeOneBytes = service.totalOfflineBytes(for: routeOne)
        let routeTwoBytes = service.totalOfflineBytes(for: routeTwo)

        XCTAssertGreaterThan(routeOneBytes, routeTwoBytes)
        XCTAssertEqual(routeOneBytes - routeTwoBytes, 8_000)
    }

    func testRemovingOneRouteKeepsSharedOfflineBundleForOtherRoutes() throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let routeOne = makeRoute(id: 201, typeCode: 2, subTypeCode: nil)
        let routeTwo = makeRoute(id: 202, typeCode: 2, subTypeCode: nil)
        let sharedTileRegionID = "shared-region-2"

        let routeOneURLs = try writeOfflineBundle(
            for: routeOne,
            baseDirectory: baseDirectory,
            gpxName: "route-one.gpx",
            metadataName: "route-one-offline-mapbox.json",
            tileRegionID: sharedTileRegionID,
            approximateByteCount: 5_000
        )
        let routeTwoURLs = try writeOfflineBundle(
            for: routeTwo,
            baseDirectory: baseDirectory,
            gpxName: "route-two.gpx",
            metadataName: "route-two-offline-mapbox.json",
            tileRegionID: sharedTileRegionID,
            approximateByteCount: 5_000
        )

        try service.removeOfflineAssets(for: routeOne)

        XCTAssertFalse(FileManager.default.fileExists(atPath: routeOneURLs.gpx.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: routeOneURLs.metadata.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: routeTwoURLs.gpx.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: routeTwoURLs.metadata.path))
    }

    func testRouteListShareabilityAuditOnlyFlagsPrivateUndownloadedRoutes() {
        let privateRoute = makeRoute(id: 301, typeCode: 2, subTypeCode: nil)
        privateRoute.isPrivate = true

        let publicUndownloadedRoute = makeRoute(id: 302, typeCode: 2, subTypeCode: nil)

        let downloadedRoute = makeRoute(id: 303, typeCode: 2, subTypeCode: nil)
        downloadedRoute.offlineGPXRelativePath = "route-303/route.gpx"
        downloadedRoute.offlineMapSnapshotRelativePath = "route-303/route-offline-mapbox.json"
        downloadedRoute.offlineDownloadedAt = .now

        let audit = RouteVaultListSyncService().auditShareability(for: [
            privateRoute,
            publicUndownloadedRoute,
            downloadedRoute,
        ])

        XCTAssertTrue(audit.hasBlockingIssues)
        XCTAssertEqual(audit.blockingPrivateRouteCount, 1)
        XCTAssertEqual(audit.issues.count, 1)
        XCTAssertEqual(audit.summaryText, "1 private route is not downloaded on this device yet.")
    }

    func testStoreOfflineAssetsGPXOnlyWritesGPXWithoutMapMetadata() async throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let route = makeRoute(id: 304, typeCode: 2, subTypeCode: nil)
        let gpxData = try service.exportGPXData(for: route)

        let storedAssets = try await service.storeOfflineAssets(
            for: route,
            gpxData: gpxData,
            selection: RouteOfflineDownloadSelection(
                includesGPX: true,
                mapStyles: [],
                includesTerrain: false
            )
        )

        XCTAssertNotNil(storedAssets.gpxRelativePath.trimmed.nilIfEmpty)
        XCTAssertNil(storedAssets.mapSnapshotRelativePath)
        XCTAssertNil(storedAssets.approximateByteCount)

        route.offlineGPXRelativePath = storedAssets.gpxRelativePath
        route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
        route.offlineDownloadedAt = storedAssets.downloadedAt

        let savedGPXURL = try XCTUnwrap(service.gpxURL(for: route))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedGPXURL.path))
        XCTAssertTrue(route.hasOfflineAssets)
    }

    func testTotalOfflineBytesCountsGPXOnlyDownload() async throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let route = makeRoute(id: 305, typeCode: 2, subTypeCode: nil)
        let gpxData = try service.exportGPXData(for: route)

        let storedAssets = try await service.storeOfflineAssets(
            for: route,
            gpxData: gpxData,
            selection: RouteOfflineDownloadSelection(
                includesGPX: true,
                mapStyles: [],
                includesTerrain: false
            )
        )

        route.offlineGPXRelativePath = storedAssets.gpxRelativePath
        route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
        route.offlineDownloadedAt = storedAssets.downloadedAt

        XCTAssertGreaterThan(service.totalOfflineBytes(for: route), 0)
    }

    func testOfflineStatusReportsExactSavedAssetMix() throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let route = makeRoute(id: 306, typeCode: 2, subTypeCode: nil)

        try writeOfflineBundle(
            for: route,
            baseDirectory: baseDirectory,
            gpxName: "route.gpx",
            metadataName: "route-outdoors-offline-mapbox.json",
            tileRegionID: "shared-region-306",
            approximateByteCount: 12_000,
            styleRawValue: AppRouteMapStyle.outdoors.rawValue,
            styleURIStrings: ["mapbox://styles/mapbox/outdoors-v12"],
            includesTerrainDEM: true
        )
        try writeOfflineBundle(
            for: route,
            baseDirectory: baseDirectory,
            gpxName: "route.gpx",
            metadataName: "route-satellite-offline-mapbox.json",
            tileRegionID: "shared-region-306",
            approximateByteCount: 12_000,
            styleRawValue: AppRouteMapStyle.satellite.rawValue,
            styleURIStrings: ["mapbox://styles/mapbox/outdoors-v12", "mapbox://styles/mapbox/satellite-v9"],
            includesTerrainDEM: true
        )

        let status = service.offlineStatus(for: route)

        XCTAssertTrue(status.hasGPX)
        XCTAssertEqual(Set(status.mapStyles.map(\.rawValue)), Set([AppRouteMapStyle.outdoors.rawValue, AppRouteMapStyle.satellite.rawValue]))
        XCTAssertTrue(status.includesTerrain)
        XCTAssertEqual(status.componentLabels, ["GPX", "Outdoors Map", "Satellite Map", "3D Terrain"])
        XCTAssertEqual(status.summaryText, "GPX • Outdoors Map • Satellite Map • 3D Terrain")
        XCTAssertEqual(status.shortBadgeText, "4 items saved")
    }

    func testOfflineStatusTreatsMissingFilesAsNeedsRefresh() throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let route = makeRoute(id: 307, typeCode: 2, subTypeCode: nil)

        route.offlineGPXRelativePath = "route-307/missing.gpx"
        route.offlineMapSnapshotRelativePath = "route-307/missing-offline-mapbox.json"
        route.offlineDownloadedAt = .now

        let status = service.offlineStatus(for: route)

        XCTAssertFalse(status.hasGPX)
        XCTAssertFalse(status.hasConcreteAssets)
        XCTAssertTrue(status.hasAnyAssets)
        XCTAssertEqual(status.summaryText, "Saved files need refresh")
        XCTAssertEqual(status.shortBadgeText, "Needs Refresh")
        XCTAssertNil(service.existingGPXData(for: route))
    }

    func testExistingGPXDataReadsOnlyPresentFiles() throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let route = makeRoute(id: 308, typeCode: 2, subTypeCode: nil)

        route.offlineGPXRelativePath = "route-308/route.gpx"
        XCTAssertNil(service.existingGPXData(for: route))

        let routeDirectory = baseDirectory.appendingPathComponent("route-308", isDirectory: true)
        try FileManager.default.createDirectory(at: routeDirectory, withIntermediateDirectories: true)
        let gpxURL = routeDirectory.appendingPathComponent("route.gpx")
        let gpxData = Data("<gpx><trk></trk></gpx>".utf8)
        try gpxData.write(to: gpxURL)

        XCTAssertEqual(service.existingGPXData(for: route), gpxData)
    }

    func testExportedGPXRoundTripsThroughGeometryOnlyImportForOfflineDownloads() async throws {
        let baseDirectory = try makeOfflineTestDirectory()
        let service = RouteOfflineAssetService(baseDirectoryOverride: baseDirectory)
        let importer = GPXImportService()
        let route = makeRoute(id: 309, typeCode: 2, subTypeCode: nil)

        let gpxData = try service.exportGPXData(for: route)
        let importedRoute = try await importer.importRoute(
            from: gpxData,
            suggestedName: route.name,
            options: .geometryOnly
        )

        XCTAssertEqual(importedRoute.name, route.name)
        XCTAssertGreaterThan(importedRoute.distanceMeters, 0)
        XCTAssertFalse(importedRoute.summaryPolyline.isEmpty)
    }

    func testRouteListSharingVisibilityKeepsLegacyPublicFlagAligned() {
        let list = RouteList(name: "Tempo Work")

        XCTAssertEqual(list.sharingVisibility, .privateAccess)
        XCTAssertFalse(list.isPublic)

        list.sharingVisibility = .invitedView
        XCTAssertTrue(list.isPublic)

        list.sharingVisibility = .linkView
        XCTAssertTrue(list.isPublic)

        list.sharingVisibility = .privateAccess
        XCTAssertFalse(list.isPublic)
    }

    func testRouteListCollaboratorCodesNormalizeInput() {
        let list = RouteList(name: "Climb Days")

        list.collaboratorCodes = [
            " tg-alpha42 ",
            "",
            "12345678"
        ]

        XCTAssertEqual(
            list.collaboratorCodes,
            ["TG-ALPHA42", RouteVaultAccountCode.accountCode(for: 12_345_678)]
        )
    }

    func testRouteListViewerCodesNormalizeInput() {
        let list = RouteList(name: "Trail Crew")

        list.viewerCodes = [
            " tg-view01 ",
            "",
            "87654321"
        ]

        XCTAssertEqual(
            list.viewerCodes,
            ["TG-VIEW01", RouteVaultAccountCode.accountCode(for: 87_654_321)]
        )
    }

    func testSharedListLinkDecodeParsesBackendShareTokensAndLegacyPayloads() throws {
        let backendURL = URL(string: "routevault://lists/shared?token=abc123")!
        let backendLink = RouteVaultSharedListLink.decode(from: backendURL)

        switch backendLink?.kind {
        case let .backendShareToken(token):
            XCTAssertEqual(token, "abc123")
        default:
            XCTFail("Expected backend share token link.")
        }

        let universalURL = try XCTUnwrap(URL(string: "https://links.routevault.app/lists/shared?token=xyz789"))
        let universalLink = RouteVaultSharedListLink.decode(from: universalURL)

        switch universalLink?.kind {
        case let .backendShareToken(token):
            XCTAssertEqual(token, "xyz789")
        default:
            XCTFail("Expected universal share token link.")
        }

        let payload = RouteListSharePayload(
            name: "Race Week",
            listDescription: "Key routes",
            isPublic: true,
            shareCode: "SHARE123",
            routes: [RouteListSharedRouteReference(routeID: 11, name: "Race Course")]
        )
        let payloadURL = try XCTUnwrap(payload.shareURL())
        let payloadLink = RouteVaultSharedListLink.decode(from: payloadURL)

        switch payloadLink?.kind {
        case let .embeddedPayload(decodedPayload):
            XCTAssertEqual(decodedPayload.name, payload.name)
            XCTAssertEqual(decodedPayload.routes.first?.routeID, 11)
        default:
            XCTFail("Expected embedded payload link.")
        }
    }

    private func makePendingStravaActivity() -> ActivityRecord {
        ActivityRecord(
            remote: StravaActivitySummaryPayload(
                id: 4242,
                name: "Pending Detail Sync",
                description: nil,
                distance: 10_000,
                movingTime: 2_700,
                elapsedTime: 2_760,
                totalElevationGain: 120,
                averageSpeed: 3.7,
                private: false,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                locationCity: "San Francisco",
                locationState: "California",
                locationCountry: "United States",
                startLatlng: [37.7749, -122.4194],
                endLatlng: [37.7849, -122.4094],
                map: StravaPolylineMapPayload(id: "a4242", summaryPolyline: "_qy`F~bsgV_pR_pR_pR_pR"),
                sportType: "Run",
                type: "Run",
                hasHeartrate: true,
                averageHeartrate: 154,
                maxHeartrate: 171
            ),
            syncedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeRoute(id: Int, typeCode: Int?, subTypeCode: Int?) -> RouteRecord {
        RouteRecord(
            remote: StravaRoutePayload(
                id: id,
                name: "Route \(id)",
                description: "",
                distance: 10_000,
                elevationGain: 250,
                estimatedMovingTime: 3_600,
                type: typeCode,
                subType: subTypeCode,
                private: false,
                starred: false,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(id)),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(id)),
                map: StravaPolylineMapPayload(id: "r\(id)", summaryPolyline: "_qy`F~bsgV_pR_pR_pR_pR"),
                segments: []
            ),
            syncedAt: Date(timeIntervalSince1970: 1_700_000_100 + TimeInterval(id))
        )
    }

    private func makeOfflineTestDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeOfflineBundle(
        for route: RouteRecord,
        baseDirectory: URL,
        gpxName: String,
        metadataName: String,
        tileRegionID: String,
        approximateByteCount: Int64,
        styleRawValue: String = AppRouteMapStyle.outdoors.rawValue,
        styleURIStrings: [String] = [],
        includesTerrainDEM: Bool = false
    ) throws -> (gpx: URL, metadata: URL) {
        let routeDirectory = baseDirectory.appendingPathComponent("route-\(route.stravaRouteID)", isDirectory: true)
        try FileManager.default.createDirectory(at: routeDirectory, withIntermediateDirectories: true)

        let gpxURL = routeDirectory.appendingPathComponent(gpxName)
        let metadataURL = routeDirectory.appendingPathComponent(metadataName)
        try Data("<gpx></gpx>".utf8).write(to: gpxURL)

        let metadata = RouteOfflineMapMetadata(
            tileRegionID: tileRegionID,
            styleRawValue: styleRawValue,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            approximateByteCount: approximateByteCount,
            styleURIStrings: styleURIStrings,
            includesTerrainDEM: includesTerrainDEM,
            geometryKind: "line",
            coverageBounds: RouteOfflineMapMetadata.CoverageBounds(
                minimumLatitude: 37.70,
                maximumLatitude: 37.82,
                minimumLongitude: -122.55,
                maximumLongitude: -122.35
            ),
            metadataVersion: 3
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataURL)

        route.offlineGPXRelativePath = "route-\(route.stravaRouteID)/\(gpxName)"
        route.offlineMapSnapshotRelativePath = "route-\(route.stravaRouteID)/\(metadataName)"
        route.offlineDownloadedAt = .now

        return (gpxURL, metadataURL)
    }

    private func makeStubSession() -> StravaSession {
        StravaSession(
            athlete: StravaAthleteProfile(
                id: 42,
                username: "tester",
                firstName: "Route",
                lastName: "Tester",
                profileMedium: nil,
                profile: nil
            ),
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            acceptedScopes: ["read_all", "activity:read", "activity:read_all"]
        )
    }
}
