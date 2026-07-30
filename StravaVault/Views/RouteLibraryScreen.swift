import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let routeLibraryHeaderRowHeight: CGFloat = 40

private struct ResolvedRouteListReference {
    let reference: RouteListSharedRouteReference
    let route: RouteRecord?
}

private func resolveRouteListReferences(
    _ references: [RouteListSharedRouteReference],
    in routes: [RouteRecord]
) -> [ResolvedRouteListReference] {
    let routesByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.stravaRouteID, $0) })
    let uniqueRoutesByName = Dictionary(grouping: routes, by: { $0.name.routeLabelIdentifier })
        .compactMapValues { matches -> RouteRecord? in
            let uniqueMatches = Array(Dictionary(uniqueKeysWithValues: matches.map { ($0.stravaRouteID, $0) }).values)
            return uniqueMatches.count == 1 ? uniqueMatches[0] : nil
        }

    return references.map { reference in
        let matchedRoute = routesByID[reference.routeID] ??
            uniqueRoutesByName[reference.name.routeLabelIdentifier]
        return ResolvedRouteListReference(reference: reference, route: matchedRoute)
    }
}

private func deduplicatedResolvedRoutes(_ references: [ResolvedRouteListReference]) -> [RouteRecord] {
    var seen = Set<Int>()
    var routes: [RouteRecord] = []

    for reference in references {
        guard let route = reference.route,
              seen.insert(route.stravaRouteID).inserted else {
            continue
        }

        routes.append(route)
    }

    return routes
}

struct RouteLibraryScreen: View {
    private enum Destination: Hashable {
        case mapBrowse
        case lists
    }

    private struct PresentedSharedList: Identifiable, Equatable {
        let shareToken: String

        var id: String { shareToken }
    }

    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.dark.rawValue
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue
    @AppStorage(AppRouteListDensity.storageKey) private var routeListDensityRawValue = AppRouteListDensity.defaultValue.rawValue
    @AppStorage(RouteTrackingActivityStore.activeRouteIDDefaultsKey) private var activeRouteTrackingRouteID = 0
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var routes: [RouteRecord]
    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var routeLists: [RouteList]
    @State private var model = RouteLibraryModel()
    @State private var isShowingGPXImporter = false
    @State private var isShowingDeletedRoutes = false
    @State private var isShowingDataExportScreen = false
    @State private var isShowingOfflineSheet = false
    @State private var isShowingManageListsScreen = false
    @State private var isShowingActivities = false
    @State private var isShowingAccountSettings = false
    @State private var isShowingFeedbackSheet = false
    @State private var navigationPath: [Destination] = []
    @State private var presentedSharedList: PresentedSharedList?
    @State private var statusBannerDismissTask: Task<Void, Never>?
    @State private var selectedRoutePresentationDetent: PresentationDetent = .medium
    @State private var didApplyScreenshotPresentation = false

    private var lightModeBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.96, blue: 0.91),
                Color(red: 0.95, green: 0.94, blue: 0.90),
                Color(red: 0.90, green: 0.90, blue: 0.88)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var activityState: RouteLibraryActivityState? {
        if AppStoreScreenshotSupport.shouldHideLibraryBanners {
            return nil
        }

        if model.isSyncing && model.isImportingGPX {
            if model.totalRouteDownloadCount > 0 {
                return .syncingAndImportingProgress(
                    completed: model.syncedRouteDownloadCount,
                    total: model.totalRouteDownloadCount,
                    isEstimated: model.isSyncRouteTotalEstimated
                )
            }

            return .syncingAndImporting
        }

        if model.isSyncing {
            if model.totalRouteDownloadCount > 0 {
                return .syncingProgress(
                    completed: model.syncedRouteDownloadCount,
                    total: model.totalRouteDownloadCount,
                    isEstimated: model.isSyncRouteTotalEstimated
                )
            }

            return .syncing
        }

        if model.isImportingGPX {
            return .importingGPX
        }

        if model.isIndexingStartLocations {
            return .indexingStartLocations(
                completed: model.indexedStartLocationCount,
                total: model.totalStartLocationIndexCount
            )
        }

        if model.isConnecting {
            return .connecting
        }

        return nil
    }

    private var sortedRouteLists: [RouteList] {
        routeLists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            libraryScrollContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    if navigationPath.isEmpty {
                        ZStack {
                            Text("Terigo")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    RouteVaultToolbarIconButton(
                                        systemImage: "map",
                                        accessibilityLabel: "Open browse map",
                                        accessibilityIdentifier: "route-library-open-map"
                                    ) {
                                        navigationPath.append(.mapBrowse)
                                    }

                                    RouteVaultToolbarIconButton(
                                        systemImage: "list.bullet",
                                        accessibilityLabel: "Open lists",
                                        accessibilityIdentifier: "route-library-open-lists"
                                    ) {
                                        navigationPath.append(.lists)
                                    }
                                }

                                Spacer(minLength: 12)

                                HStack(spacing: 12) {
                                    RouteVaultToolbarIconButton(
                                        systemImage: "questionmark",
                                        accessibilityLabel: "Send tester feedback",
                                        accessibilityIdentifier: "route-library-send-feedback"
                                    ) {
                                        isShowingFeedbackSheet = true
                                    }

                                    routeLibrarySettingsMenu
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: routeLibraryHeaderRowHeight)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .background(Color.clear)
                    }
                }
                .background {
                    if colorScheme == .dark {
                        Color.black.ignoresSafeArea()
                    } else {
                        lightModeBackgroundGradient.ignoresSafeArea()
                    }
                }
                .navigationTitle(navigationPath.isEmpty ? "" : "Terigo")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .mapBrowse:
                        RouteMapBrowseSheet(
                            model: model,
                            allRoutes: routes,
                            lists: sortedRouteLists
                        )
                    case .lists:
                        RouteListsScreen { list in
                            deleteListEverywhere(list)
                        }
                    }
                }
        }
            .refreshable {
                if model.isConnected {
                    await model.syncRoutes(using: modelContext)
                }
            }
            .task {
                model.migrateLegacyListsIfNeeded(using: modelContext)
                await model.performInitialSyncIfNeeded(using: modelContext)
                model.scheduleStartLocationIndexing(using: modelContext)
            }
            .task(id: screenshotPresentationSignature) {
                await applyAppStoreScreenshotPresentationIfNeeded()
            }
            .task(id: spotlightIndexSignature) {
                await RouteSpotlightIndexer.reindex(routes: routes)
            }
            .task(id: remoteListSyncSignature) {
                await syncListsIfPossible()
            }
            .task(id: accountManager.pendingSharedListLink.map(sharedListLinkSignature)) {
                await handlePendingSharedListLink()
            }
            .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
                handleSpotlightActivity(userActivity)
            }
            .onOpenURL { url in
                accountManager.captureIncomingURL(url)
            }
            .onChange(of: model.statusMessage) { _, newValue in
                scheduleStatusBannerDismiss(for: newValue)
            }
            .onDisappear {
                statusBannerDismissTask?.cancel()
                statusBannerDismissTask = nil
            }
            .sheet(item: selectedRouteBinding) { route in
                NavigationStack {
                    RouteEditorSheet(
                        route: route,
                        onDelete: { routeToDelete in
                            model.deleteRoute(routeToDelete, using: modelContext)
                        }
                    )
                }
                .presentationDetents([.medium, .large], selection: $selectedRoutePresentationDetent)
            }
            .sheet(isPresented: $isShowingDeletedRoutes) {
                NavigationStack {
                    DeletedRoutesSheet(model: model)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isShowingDataExportScreen) {
                NavigationStack {
                    DataExportScreen()
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isShowingOfflineSheet) {
                NavigationStack {
                    RouteOfflineCenterSheet(
                        visibleRoutes: model.filteredRoutes(from: routes)
                    )
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isShowingManageListsScreen) {
                NavigationStack {
                    RouteListsScreen { list in
                        deleteListEverywhere(list)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") {
                                isShowingManageListsScreen = false
                            }
                        }
                    }
                }
                .preferredColorScheme(appAppearanceSelection.wrappedValue.colorScheme)
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isShowingAccountSettings) {
                NavigationStack {
                    RouteVaultAccountSettingsSheet()
                        .environment(accountManager)
                }
                .presentationDetents([.fraction(0.76), .large])
            }
            .sheet(isPresented: $isShowingFeedbackSheet) {
                NavigationStack {
                    RouteVaultFeedbackSheet()
                        .environment(accountManager)
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $isShowingActivities) {
                ActivitiesScreen(showsDismissButton: true)
            }
            .sheet(item: $presentedSharedList) { presentedSharedList in
                NavigationStack {
                    SharedRouteListScreen(shareToken: presentedSharedList.shareToken)
                }
                .presentationDetents([.large])
            }
            .fileImporter(
                isPresented: $isShowingGPXImporter,
                allowedContentTypes: [.gpxRoute],
                allowsMultipleSelection: true,
                onCompletion: handleGPXImportSelection
            )
    }

    private var libraryScrollContent: some View {
        let filteredRoutes = model.filteredRoutes(from: routes)
        let showsLibrary = model.isConnected || !routes.isEmpty

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !AppStoreScreenshotSupport.shouldHideLibraryBanners {
                    if let errorMessage = visibleBannerMessage(accountManager.errorMessage) {
                        BannerView(message: errorMessage, tone: .error)
                            .onTapGesture {
                                accountManager.clearTransientMessages()
                            }
                    }

                    if let statusMessage = visibleBannerMessage(accountManager.statusMessage) {
                        BannerView(message: statusMessage, tone: .success)
                            .onTapGesture {
                                accountManager.clearTransientMessages()
                            }
                    }

                    if let errorMessage = visibleBannerMessage(model.errorMessage) {
                        BannerView(message: errorMessage, tone: .error)
                    }

                    if let statusMessage = visibleBannerMessage(model.statusMessage) {
                        BannerView(message: statusMessage, tone: .success)
                    }

                    if let activityState {
                        LibraryActivityBanner(state: activityState)
                    }
                }

                if !model.isConnected {
                    ConnectionSection(model: model)
                }

                if showsLibrary {
                    ControlsSection(
                        model: model,
                        allRoutes: routes,
                        lists: sortedRouteLists
                    )
                    .id("controls-\(appMeasurementSystemRawValue)")

                    RouteResultsSection(
                        filteredRoutes: filteredRoutes,
                        allLists: sortedRouteLists,
                        routeCount: routes.count,
                        density: routeListDensity,
                        hasActiveFilters: model.hasActiveFilters,
                        isSyncing: model.isSyncing,
                        onResetFilters: model.resetFilters,
                        onDeleteRoute: { route in
                            model.deleteRoute(route, using: modelContext, showsStatusMessage: false)
                        },
                        onToggleRouteList: { route, list in
                            route.listNames = route.toggledListNames(with: list.name)
                            try? modelContext.save()
                            model.errorMessage = nil
                        },
                        onReportStatus: { message in
                            _ = message
                        },
                        onReportError: { message in
                            model.errorMessage = message
                        }
                    ) { route in
                        model.selectedRoute = route
                    }
                    .id("results-\(appMeasurementSystemRawValue)-\(routeListDensityRawValue)")
                } else {
                    DisconnectedEmptyState(isImportingGPX: model.isImportingGPX)
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("route-library-screen")
    }

    private var remoteListSyncSignature: Int {
        var hasher = Hasher()
        hasher.combine(accountManager.canUseBackendFeatures)
        hasher.combine(accountManager.accountSession?.token ?? "")

        for list in routeLists.sorted(by: { $0.id < $1.id }) {
            hasher.combine(list.id)
            hasher.combine(list.name)
            hasher.combine(list.listDescription)
            hasher.combine(list.sharingVisibilityRawValue)
            hasher.combine(list.collaborationModeRawValue)
            hasher.combine(list.collaboratorEmailsBlob ?? "")
            hasher.combine(list.viewerEmailsBlob ?? "")
            hasher.combine(list.remoteListID ?? "")
            hasher.combine(list.remoteShareToken ?? "")
            hasher.combine(list.remoteAccessRoleRawValue ?? "")
            hasher.combine(list.remoteRevision)
            hasher.combine(list.lastRemoteSyncFingerprint ?? "")
        }

        for route in routes.sorted(by: { $0.stravaRouteID < $1.stravaRouteID }) {
            hasher.combine(route.stravaRouteID)
            hasher.combine(route.collectionName)
            hasher.combine(route.tagsBlob)
            hasher.combine(route.offlineGPXRelativePath ?? "")
        }

        return hasher.finalize()
    }

    private func sharedListLinkSignature(_ link: RouteVaultSharedListLink) -> String {
        switch link.kind {
        case let .backendShareToken(token):
            return "remote-\(token)"
        case let .embeddedPayload(payload):
            return "payload-\(payload.shareCode)"
        }
    }

    @MainActor
    private func syncListsIfPossible() async {
        guard accountManager.canUseBackendFeatures else {
            return
        }

        let listSyncService = RouteVaultListSyncService()

        try? await Task.sleep(nanoseconds: 600_000_000)
        var encounteredConflict = false

        for list in routeLists {
            let listRoutes = routes.filter { $0.hasList(named: list.name) }
            guard listSyncService.shouldSync(list: list, routes: listRoutes) else {
                continue
            }

            let syncFingerprint = listSyncService.fingerprint(for: list, routes: listRoutes)

            do {
                let response = try await listSyncService.sync(list: list, routes: listRoutes)
                list.remoteListID = response.listID
                list.remoteOwnerAccountID = response.ownerAccountID
                list.remoteShareToken = response.shareToken
                list.remoteAccessRole = .owner
                list.remoteRevision = response.revision
                list.lastRemoteSyncAt = response.updatedAt
                list.lastRemoteSyncFingerprint = syncFingerprint
                list.updatedAt = response.updatedAt
            } catch let error as RouteVaultBackendService.BackendError {
                if case .unauthorized = error,
                   await accountManager.refreshBackendSessionAfterUnauthorized() {
                    do {
                        let response = try await listSyncService.sync(list: list, routes: listRoutes)
                        list.remoteListID = response.listID
                        list.remoteOwnerAccountID = response.ownerAccountID
                        list.remoteShareToken = response.shareToken
                        list.remoteAccessRole = .owner
                        list.remoteRevision = response.revision
                        list.lastRemoteSyncAt = response.updatedAt
                        list.lastRemoteSyncFingerprint = syncFingerprint
                        list.updatedAt = response.updatedAt
                        continue
                    } catch let retryError as RouteVaultBackendService.BackendError {
                        if case .conflict = retryError {
                            encounteredConflict = true
                        }
                    } catch {
                    }
                }

                if case .conflict = error {
                    encounteredConflict = true
                } else {
                    accountManager.errorMessage = error.localizedDescription
                }
                continue
            } catch {
                continue
            }
        }

        if !encounteredConflict {
            await hydrateRemoteListsIfPossible()
        }
        try? modelContext.save()
    }

    private var routeLibrarySettingsMenu: some View {
        Menu {
            Section("Account") {
                Button {
                    isShowingAccountSettings = true
                } label: {
                    Label("Manage Account", systemImage: "person.crop.circle")
                }
            }

            Section("Library") {
                Button {
                    isShowingActivities = true
                } label: {
                    Label("Activities", systemImage: "figure.run")
                }
                .accessibilityIdentifier("route-library-open-activities")

                Button {
                    isShowingOfflineSheet = true
                } label: {
                    Label(
                        offlineMenuTitle,
                        systemImage: "arrow.down.circle"
                    )
                }
                .accessibilityIdentifier("route-library-open-offline-center")

                Button {
                    isShowingManageListsScreen = true
                } label: {
                    Label("Manage Lists", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("route-library-open-manage-lists")

                Button {
                    isShowingGPXImporter = true
                } label: {
                    Label(model.isImportingGPX ? "Importing..." : "Import GPX", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(model.isImportingGPX)

                Button {
                    isShowingDeletedRoutes = true
                } label: {
                    Label(
                        model.deletedRoutes.isEmpty ? "Deleted Routes" : "Deleted Routes (\(model.deletedRoutes.count))",
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier("route-library-open-deleted-routes")

                Button {
                    isShowingDataExportScreen = true
                } label: {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("route-library-open-export-data")
            }

            Section("Preferences") {
                Menu {
                    Picker("Appearance", selection: appAppearanceSelection) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Label(appearance.title, systemImage: appearance.symbolName)
                                .tag(appearance)
                        }
                    }

                    Picker("Units", selection: appMeasurementSystemSelection) {
                        ForEach(AppMeasurementSystem.allCases) { measurementSystem in
                            Label(measurementSystem.title, systemImage: measurementSystem.symbolName)
                                .tag(measurementSystem)
                        }
                    }

                    Picker("Route View", selection: routeListDensitySelection) {
                        ForEach(AppRouteListDensity.allCases) { density in
                            Label(density.title, systemImage: density.symbolName)
                                .tag(density)
                        }
                    }
                } label: {
                    Label("Display Settings", systemImage: "slider.horizontal.3")
                }
            }

            Section("Strava") {
                if let session = model.session {
                    Menu {
                        if model.isConnected {
                            Button {
                                Task { await model.syncRoutes(using: modelContext) }
                            } label: {
                                Label(model.isSyncing ? "Syncing..." : "Sync Routes", systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isSyncing)
                        }

                        Button {
                            Task { await model.connect() }
                        } label: {
                            Label("Reconnect Strava", systemImage: "link.badge.plus")
                        }

                        Button(
                            session.hasReadAllAccess ? "read_all enabled" : "Limited Strava access",
                            systemImage: session.hasReadAllAccess ? "checkmark.seal" : "exclamationmark.triangle"
                        ) { }
                        .disabled(true)

                        Button("Disconnect", role: .destructive) {
                            model.disconnect()
                        }
                    } label: {
                        Label("Connection", systemImage: "link")
                    }
                } else {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        Label(model.isConnecting ? "Connecting..." : "Connect Strava", systemImage: "link.badge.plus")
                    }
                    .disabled(model.isConnecting)
                }
            }
        } label: {
            RouteVaultToolbarIconGlyph(systemImage: "ellipsis")
                .contentShape(Circle())
                .accessibilityLabel("Route library settings")
                .accessibilityIdentifier("route-library-settings-button")
        }
    }

    private var selectedRouteBinding: Binding<RouteRecord?> {
        Binding(
            get: { model.selectedRoute },
            set: { model.selectedRoute = $0 }
        )
    }

    private var appAppearanceSelection: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appAppearanceRawValue) ?? .dark },
            set: { appAppearanceRawValue = $0.rawValue }
        )
    }

    private var appMeasurementSystemSelection: Binding<AppMeasurementSystem> {
        Binding(
            get: { AppMeasurementSystem(rawValue: appMeasurementSystemRawValue) ?? AppMeasurementSystem.defaultValue },
            set: { appMeasurementSystemRawValue = $0.rawValue }
        )
    }

    private var routeListDensitySelection: Binding<AppRouteListDensity> {
        Binding(
            get: { AppRouteListDensity(rawValue: routeListDensityRawValue) ?? AppRouteListDensity.defaultValue },
            set: { routeListDensityRawValue = $0.rawValue }
        )
    }

    private var routeListDensity: AppRouteListDensity {
        AppRouteListDensity(rawValue: routeListDensityRawValue) ?? AppRouteListDensity.defaultValue
    }

    private var offlineMenuTitle: String {
        let savedCount = routes.filter(\.hasOfflineAssets).count
        if savedCount == 0 {
            return "Offline"
        }

        return savedCount == 1 ? "Offline (1 saved)" : "Offline (\(savedCount) saved)"
    }

    private var spotlightIndexSignature: Int {
        var hasher = Hasher()
        hasher.combine(routes.count)
        for route in routes {
            hasher.combine(route.stravaRouteID)
            hasher.combine(route.primaryTimestamp.timeIntervalSinceReferenceDate)
            hasher.combine(route.syncedAt.timeIntervalSinceReferenceDate)
            hasher.combine(route.listNames.count)
        }
        return hasher.finalize()
    }

    private var screenshotPresentationSignature: String {
        "\(AppStoreScreenshotSupport.requestedShot?.rawValue ?? "none")-\(routes.count)-\(model.isSyncing ? "syncing" : "idle")"
    }

    @MainActor
    private func applyAppStoreScreenshotPresentationIfNeeded() async {
        guard let shot = AppStoreScreenshotSupport.requestedShot,
              !didApplyScreenshotPresentation,
              !model.isSyncing,
              !routes.isEmpty else {
            return
        }

        let preferredRoute = AppStoreScreenshotSupport.preferredShowcaseRoute(in: routes)

        switch shot {
        case .routeLibrary:
            selectedRoutePresentationDetent = .medium
            model.selectedRoute = nil
            activeRouteTrackingRouteID = 0
        case .mapBrowseSanFrancisco:
            navigationPath = [.mapBrowse]
            model.selectedRoute = nil
            activeRouteTrackingRouteID = 0
        case .sortOrder:
            model.sortCriteria = AppStoreScreenshotSupport.previewSortCriteria
            model.selectedRoute = nil
            activeRouteTrackingRouteID = 0
        case .routeFullScreenMap, .routeDetailsWeather:
            guard let preferredRoute else {
                return
            }
            selectedRoutePresentationDetent = .large
            activeRouteTrackingRouteID = 0
            model.selectedRoute = preferredRoute
        case .liveTracking:
            guard let preferredRoute else {
                return
            }
            model.selectedRoute = nil
            activeRouteTrackingRouteID = preferredRoute.stravaRouteID
        }

        didApplyScreenshotPresentation = true
    }

    private func handleSpotlightActivity(_ userActivity: NSUserActivity) {
        guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return
        }

        switch RouteSpotlightIdentifier.parse(identifier) {
        case .route(let routeID)?:
            guard let route = routes.first(where: { $0.stravaRouteID == routeID }) else {
                model.errorMessage = "That Spotlight route is no longer available locally."
                return
            }

            model.selectedRoute = route
        case nil:
            return
        }
    }

    private func handleGPXImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                return
            }

            Task {
                let importedRoute = await model.importGPXFiles(from: urls, using: modelContext)
                if let importedRoute {
                    model.selectedRoute = importedRoute
                }
            }
        case .failure(let error):
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func handlePendingSharedListLink() async {
        guard let pendingLink = accountManager.consumePendingSharedListLink() else {
            return
        }

        switch pendingLink.kind {
        case let .embeddedPayload(payload):
            importSharedList(payload)
        case let .backendShareToken(shareToken):
            presentedSharedList = PresentedSharedList(shareToken: shareToken)
        }
    }

    private func visibleBannerMessage(_ value: String?) -> String? {
        guard let message = value?.trimmed.nilIfEmpty else {
            return nil
        }

        if message.caseInsensitiveCompare("cancelled") == .orderedSame {
            return nil
        }

        return message
    }

    private func scheduleStatusBannerDismiss(for value: String?) {
        statusBannerDismissTask?.cancel()
        statusBannerDismissTask = nil

        guard let message = visibleBannerMessage(value) else {
            return
        }

        statusBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else {
                return
            }

            if model.statusMessage == message {
                model.statusMessage = nil
            }
        }
    }

    private func deleteListEverywhere(_ list: RouteList) {
        let listToken = list.name.routeLabelIdentifier
        guard !listToken.isEmpty else {
            return
        }

        if list.remoteAccessRole == .follower,
           let shareToken = list.remoteShareToken?.trimmed.nilIfEmpty,
           let accountSession = accountManager.accountSession {
            Task {
                try? await RouteVaultBackendService().setFollowState(
                    shareToken: shareToken,
                    isFollowing: false,
                    accountSessionToken: accountSession.token
                )
            }
        }

        for route in routes where route.hasList(named: list.name) {
            route.listNames = route.removingList(named: list.name)
        }

        model.removeSelectedTag(list.name)
        modelContext.delete(list)
        try? modelContext.save()
    }

    @MainActor
    private func hydrateRemoteListsIfPossible() async {
        guard !accountManager.isReviewerDemoActive else {
            return
        }

        let backendService = RouteVaultBackendService()
        guard let response = await fetchRemoteLists(using: backendService) else {
            return
        }

        for remoteList in response.lists {
            mergeRemoteList(remoteList)
        }

        try? modelContext.save()
    }

    @MainActor
    private func fetchRemoteLists(using backendService: RouteVaultBackendService) async -> RouteVaultAccountListsResponse? {
        guard !accountManager.isReviewerDemoActive else {
            return nil
        }

        guard let accountSession = accountManager.accountSession else {
            return nil
        }

        do {
            return try await backendService.fetchAccountLists(accountSessionToken: accountSession.token)
        } catch let error as RouteVaultBackendService.BackendError {
            if case .unauthorized = error,
               await accountManager.refreshBackendSessionAfterUnauthorized(),
               let refreshedSession = accountManager.accountSession {
                return try? await backendService.fetchAccountLists(accountSessionToken: refreshedSession.token)
            }

            accountManager.errorMessage = error.localizedDescription
            return nil
        } catch {
            accountManager.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func mergeRemoteList(_ remoteList: RouteVaultAccountListPayload) {
        let listSyncService = RouteVaultListSyncService()
        let remoteReferences = remoteList.routes.map {
            RouteListSharedRouteReference(routeID: $0.stravaRouteID, name: $0.name)
        }
        let existingList = routeLists.first {
            $0.remoteListID == remoteList.listID || (
                $0.remoteAccessRole == .follower &&
                $0.remoteShareToken == remoteList.shareToken
            )
        }

        let list = existingList ?? RouteList(
            name: makeUniqueListName(remoteList.name, excluding: routeLists.map(\.name)),
            listDescription: remoteList.listDescription,
            shareCode: RouteList.makeShareCode(),
            sharingVisibility: RouteListVisibilityMode(rawValue: remoteList.visibility),
            collaborationMode: RouteListCollaborationMode(rawValue: remoteList.collaborationMode) ?? .ownerOnly,
            remoteListID: remoteList.listID,
            remoteOwnerAccountID: remoteList.ownerAccountID,
            remoteOwnerDisplayName: remoteList.ownerDisplayName,
            remoteShareToken: remoteList.shareToken,
            remoteAccessRole: remoteList.relationship,
            remoteRevision: remoteList.revision,
            lastRemoteSyncAt: remoteList.updatedAt,
            collaboratorCodes: remoteList.collaboratorCodes,
            viewerCodes: remoteList.viewerCodes,
            importedRouteReferences: remoteReferences
        )

        if existingList == nil {
            modelContext.insert(list)
        }

        if let existingList,
           existingList.remoteAccessRole?.isOwnedByCurrentAccount != false {
            let localRoutes = routes.filter { $0.hasList(named: existingList.name) }
            let hasUnsyncedLocalChanges = listSyncService.shouldSync(list: existingList, routes: localRoutes)
            let remoteRevisionIsNotNewer = remoteList.revision <= existingList.remoteRevision
            if hasUnsyncedLocalChanges && remoteRevisionIsNotNewer {
                return
            }
        }

        let previousName = list.name
        let localMatchingRouteIDs = Set(routes.filter { $0.hasList(named: previousName) }.map(\.stravaRouteID))
        let remoteRouteIDs = Set(deduplicatedResolvedRoutes(resolveRouteListReferences(remoteReferences, in: routes)).map(\.stravaRouteID))
        let mergedName = makeUniqueListName(
            remoteList.name,
            excluding: routeLists
                .filter { $0.id != list.id }
                .map(\.name)
        )

        list.name = mergedName
        list.listDescription = remoteList.listDescription
        list.sharingVisibility = RouteListVisibilityMode(rawValue: remoteList.visibility) ?? .privateAccess
        list.collaborationMode = RouteListCollaborationMode(rawValue: remoteList.collaborationMode) ?? .ownerOnly
        list.collaboratorCodes = remoteList.collaboratorCodes
        list.viewerCodes = remoteList.viewerCodes
        list.remoteListID = remoteList.listID
        list.remoteOwnerAccountID = remoteList.ownerAccountID
        list.remoteOwnerDisplayName = remoteList.ownerDisplayName
        list.remoteShareToken = remoteList.shareToken
        list.remoteAccessRole = remoteList.relationship
        list.remoteRevision = remoteList.revision
        list.lastRemoteSyncAt = remoteList.updatedAt
        list.importedRouteReferences = remoteReferences

        for route in routes {
            let isInRemoteList = remoteRouteIDs.contains(route.stravaRouteID)
            let wasInLocalList = localMatchingRouteIDs.contains(route.stravaRouteID) || route.hasList(named: previousName)

            if isInRemoteList {
                var labels = route.listNames
                if previousName != list.name {
                    labels = route.removingList(named: previousName)
                }
                route.listNames = RouteRecord.normalizedLabels(labels + [list.name])
            } else if wasInLocalList {
                route.listNames = route.removingList(named: previousName)
            }
        }

        let currentRoutes = routes.filter { $0.hasList(named: list.name) }
        list.lastRemoteSyncFingerprint = listSyncService.fingerprint(for: list, routes: currentRoutes)
        list.updatedAt = remoteList.updatedAt
    }

    private func importSharedList(_ payload: RouteListSharePayload) {
        let baseName = payload.name.trimmed.nilIfEmpty ?? "Shared List"
        let existingNames = routeLists.map(\.name)
        let importedName = makeUniqueListName(baseName, excluding: existingNames)
        let importedList = RouteList(
            name: importedName,
            listDescription: payload.listDescription,
            isPublic: payload.isPublic,
            shareCode: payload.shareCode,
            importedRouteReferences: payload.routes
        )

        modelContext.insert(importedList)

        let matchedRoutes = deduplicatedResolvedRoutes(resolveRouteListReferences(payload.routes, in: routes))
        for route in matchedRoutes {
            route.listNames = RouteRecord.normalizedLabels(route.listNames + [importedList.name])
        }

        do {
            try modelContext.save()
            let importedCount = matchedRoutes.count
            let missingCount = payload.routes.count - importedCount
            if missingCount > 0 {
                model.statusMessage = "Imported \(importedList.name) with \(importedCount) matching routes. \(missingCount) routes are not in your library yet."
            } else {
                model.statusMessage = "Imported shared list \(importedList.name)."
            }
            model.errorMessage = nil
            if navigationPath.last != .lists {
                navigationPath.append(.lists)
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func makeUniqueListName(_ baseName: String, excluding existingNames: [String]) -> String {
        let normalizedExistingNames = Set(existingNames.map(\.routeLabelIdentifier))
        let trimmedBaseName = baseName.trimmed.nilIfEmpty ?? "List"
        if !normalizedExistingNames.contains(trimmedBaseName.routeLabelIdentifier) {
            return trimmedBaseName
        }

        var suffix = 2
        while true {
            let candidate = "\(trimmedBaseName) \(suffix)"
            if !normalizedExistingNames.contains(candidate.routeLabelIdentifier) {
                return candidate
            }
            suffix += 1
        }
    }
}

private struct RouteVaultToolbarIconGlyph: View {
    let systemImage: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

private struct RouteVaultToolbarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RouteVaultToolbarIconGlyph(systemImage: systemImage)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct RouteVaultAccountSettingsSheet: View {
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        Form {
            if accountManager.isReviewerDemoActive {
                Section("Reviewer Demo Mode") {
                    Text("This device is using seeded local demo routes, lists, and activities so App Review can exercise the full app without a live Strava account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Exit Demo Mode", role: .destructive) {
                        accountManager.deactivateReviewDemo(using: modelContext)
                        dismiss()
                    }
                }
            }

            Section("Terigo Account") {
                if let profile = accountManager.accountSession?.profile {
                    LabeledContent("Name", value: profile.displayName)
                    LabeledContent("Account Code", value: profile.accountCode)
                } else {
                    Text(accountManager.backendStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sharing Identity") {
                if let accountCode = accountManager.accountCode {
                    Button {
                        UIPasteboard.general.string = accountCode
                        accountManager.statusMessage = "Copied your Terigo account code."
                    } label: {
                        Label("Copy Account Code", systemImage: "doc.on.doc")
                    }
                }

                Text(accountManager.isReviewerDemoActive
                     ? "Reviewer demo mode keeps sharing local to this device. The account code is shown so list-sharing screens still demonstrate the full flow."
                     : "Private collaboration now uses Strava-backed Terigo account codes instead of invite email. Share this code with friends so they can be added to specific-viewer or specific-editor lists.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !accountManager.isReviewerDemoActive,
               accountManager.accountSession != nil {
                Section("Account Data") {
                    Text("Deleting your account removes your hosted Terigo profile, synced lists, sharing permissions, feedback, and stored shared-route files. Routes saved only on this iPhone stay on the device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Delete Terigo Account", role: .destructive) {
                        isConfirmingAccountDeletion = true
                    }
                    .disabled(accountManager.isDeletingAccount)
                }
            }

            if let errorMessage = accountManager.errorMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            } else if let statusMessage = accountManager.statusMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Delete your Terigo account?",
            isPresented: $isConfirmingAccountDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Account and Hosted Data", role: .destructive) {
                Task {
                    if await accountManager.deleteAccount() {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Your Strava account is not deleted, and routes stored only on this iPhone remain until you remove them or delete the app.")
        }
    }
}

private struct RouteVaultFeedbackSheet: View {
    @Environment(RouteVaultAccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Testing Feedback") {
                Text(accountManager.isReviewerDemoActive
                     ? "Reviewer demo mode keeps feedback on-device only. Use this screen to verify the flow without sending anything to the live backend."
                     : "Use this temporary testing form to report bugs, friction, or ideas directly from the app. Terigo will attach the feedback to your signed-in account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if message.trimmed.isEmpty {
                        Text("What happened? What were you trying to do?")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }

                    TextEditor(text: $message)
                        .frame(minHeight: 180)
                        .onChange(of: message) { _, newValue in
                            if newValue.count > 4_000 {
                                message = String(newValue.prefix(4_000))
                            }
                        }
                }

                Text("\(message.count)/4,000")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let accountCode = accountManager.accountCode {
                Section("Account") {
                    LabeledContent("From", value: accountCode)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Send Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(isSubmitting ? "Sending…" : "Send") {
                    Task { await submitFeedback() }
                }
                .disabled(isSubmitting || message.trimmed.isEmpty)
            }
        }
    }

    @MainActor
    private func submitFeedback() async {
        if accountManager.isReviewerDemoActive {
            accountManager.errorMessage = nil
            accountManager.statusMessage = "Reviewer demo mode keeps feedback local only."
            dismiss()
            return
        }

        guard let accountSession = accountManager.accountSession else {
            errorMessage = "Terigo account sync is still reconnecting. Try again in a moment."
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await RouteVaultBackendService().submitFeedback(
                message: message.trimmed,
                sourceScreen: "route_library",
                accountSessionToken: accountSession.token
            )
            accountManager.errorMessage = nil
            accountManager.statusMessage = "Feedback sent. Thanks for testing Terigo."
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct RouteListsScreen: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var allLists: [RouteList]
    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var allRoutes: [RouteRecord]

    let onDeleteList: (RouteList) -> Void

    @State private var newListDraft = ""
    @State private var pendingDeletionList: RouteList?
    @State private var message: String?

    var body: some View {
        let usageCounts = listUsageCounts

        Form {
            Section("Create List") {
                HStack(spacing: 12) {
                    TextField("List name", text: $newListDraft)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    Button("Add", action: addList)
                        .buttonStyle(.borderedProminent)
                        .disabled(newListDraft.trimmed.isEmpty)
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("All Lists") {
                if sortedLists.isEmpty {
                    ContentUnavailableView(
                        "No Lists Yet",
                        systemImage: "list.bullet",
                        description: Text("Create lists here, then add routes to them from route details or quick actions.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(sortedLists) { list in
                        NavigationLink {
                            RouteListDetailScreen(list: list, onDeleteList: onDeleteList)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(list.name)
                                        .font(.headline)

                                    HStack(spacing: 8) {
                                        Text(usageLabel(for: list, usageCounts: usageCounts))
                                        Text(list.sharingVisibility.title)
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                if list.sharingVisibility != .privateAccess {
                                    Image(systemName: "link")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("route-list-row-\(list.normalizedName.replacingOccurrences(of: " ", with: "-"))")
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletionList = list
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage Lists")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("manage-lists-screen")
        .confirmationDialog(
            "Delete List?",
            isPresented: pendingDeletionBinding,
            titleVisibility: .visible
        ) {
            if let pendingDeletionList {
                Button("Delete List", role: .destructive) {
                    deleteList(pendingDeletionList)
                }
            }

            Button("Cancel", role: .cancel) {
                pendingDeletionList = nil
            }
        } message: {
            if let pendingDeletionList {
                Text("This removes `\(pendingDeletionList.name)` from every route and deletes the list details.")
            }
        }
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionList != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionList = nil
                }
            }
        )
    }

    private var sortedLists: [RouteList] {
        allLists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var listUsageCounts: [String: Int] {
        Dictionary(grouping: allRoutes.flatMap(\.listNames), by: { $0.routeLabelIdentifier })
            .mapValues(\.count)
    }

    private func addList() {
        let trimmedListName = newListDraft.trimmed
        guard !trimmedListName.isEmpty else {
            return
        }

        guard !allLists.contains(where: { $0.normalizedName == trimmedListName.routeLabelIdentifier }) else {
            message = "A list with that name already exists."
            return
        }

        modelContext.insert(RouteList(name: trimmedListName))
        newListDraft = ""
        message = nil
        try? modelContext.save()
    }

    private func deleteList(_ list: RouteList) {
        onDeleteList(list)
        pendingDeletionList = nil
    }

    private func usageLabel(for list: RouteList, usageCounts: [String: Int]) -> String {
        let usageCount = usageCounts[list.normalizedName] ?? 0
        return usageCount == 0
            ? "Empty list"
            : "\(usageCount) \(usageCount == 1 ? "route" : "routes")"
    }
}

private struct RouteListDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var allRoutes: [RouteRecord]
    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var allLists: [RouteList]

    @Bindable var list: RouteList
    let onDeleteList: (RouteList) -> Void

    @State private var libraryModel = RouteLibraryModel()
    @State private var selectedRoute: RouteRecord?
    @State private var isShowingMapBrowse = false
    @State private var isShowingRenamePrompt = false
    @State private var renameDraft: String
    @State private var isShowingDescriptionEditor = false
    @State private var descriptionDraft: String
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var isDownloadingOffline = false
    @State private var offlineDownloadProgress: RouteOfflineDownloadProgress?
    @State private var isShowingSharingSheet = false

    private let offlineDownloadCoordinator = RouteOfflineDownloadCoordinator()

    init(list: RouteList, onDeleteList: @escaping (RouteList) -> Void) {
        self.list = list
        self.onDeleteList = onDeleteList
        _renameDraft = State(initialValue: list.name)
        _descriptionDraft = State(initialValue: list.listDescription)
    }

    var body: some View {
        let sortedLists = allLists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let snapshot = contentSnapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let errorMessage = visibleBannerMessage(errorMessage ?? libraryModel.errorMessage) {
                    BannerView(message: errorMessage, tone: .error)
                }

                if let statusMessage = visibleBannerMessage(statusMessage ?? libraryModel.statusMessage) {
                    BannerView(message: statusMessage, tone: .success)
                }

                ControlsSection(
                    model: libraryModel,
                    allRoutes: snapshot.routes,
                    lists: sortedLists
                )

                RouteResultsSection(
                    filteredRoutes: snapshot.filteredRoutes,
                    allLists: sortedLists,
                    routeCount: snapshot.routes.count,
                    density: preferredDensity,
                    hasActiveFilters: libraryModel.hasActiveFilters,
                    isSyncing: false,
                    onResetFilters: libraryModel.resetFilters,
                    onDeleteRoute: { route in
                        libraryModel.deleteRoute(route, using: modelContext)
                    },
                    onToggleRouteList: { route, list in
                        route.listNames = route.toggledListNames(with: list.name)
                        try? modelContext.save()
                        statusMessage = route.hasList(named: list.name)
                            ? "Added \(route.name) to \(list.name)."
                            : "Removed \(route.name) from \(list.name)."
                        errorMessage = nil
                        libraryModel.statusMessage = nil
                        libraryModel.errorMessage = nil
                    },
                    onReportStatus: { message in
                        statusMessage = message
                        errorMessage = nil
                        libraryModel.statusMessage = nil
                        libraryModel.errorMessage = nil
                    },
                    onReportError: { message in
                        errorMessage = message
                    }
                ) { route in
                    selectedRoute = route
                }

                if !snapshot.missingImportedRoutes.isEmpty {
                    MissingImportedRoutesPanel(references: snapshot.missingImportedRoutes)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                Text(list.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 88)

                HStack(spacing: 12) {
                    RouteVaultToolbarIconButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "Back",
                        accessibilityIdentifier: "route-list-go-back"
                    ) {
                        dismiss()
                    }

                    Spacer(minLength: 12)

                    listHeaderOverlay(routes: snapshot.routes)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: routeLibraryHeaderRowHeight)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("route-list-detail-screen-\(list.normalizedName.replacingOccurrences(of: " ", with: "-"))")
        .task(id: importedRouteRepairKey) {
            repairImportedRouteMembershipsIfNeeded()
        }
        .alert("Edit List Name", isPresented: $isShowingRenamePrompt) {
            TextField("List name", text: $renameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Save") {
                renameList(to: renameDraft)
            }
            Button("Cancel", role: .cancel) {
                renameDraft = list.name
            }
        }
        .sheet(isPresented: $isShowingDescriptionEditor) {
            NavigationStack {
                RouteListDescriptionEditorSheet(
                    title: list.name,
                    initialDescription: list.listDescription
                ) { updatedDescription in
                    updateDescription(to: updatedDescription)
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isShowingMapBrowse) {
            NavigationStack {
                RouteMapBrowseSheet(
                    model: libraryModel,
                    allRoutes: snapshot.routes,
                    lists: sortedLists
                )
            }
            .presentationDetents([.large])
        }
        .sheet(item: $selectedRoute) { route in
            NavigationStack {
                RouteEditorSheet(
                    route: route,
                    onDelete: { routeToDelete in
                        onDeleteRoute(routeToDelete)
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingSharingSheet) {
            NavigationStack {
                RouteListSharingSheet(list: list, routes: snapshot.routes)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete List?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete List", role: .destructive) {
                onDeleteList(list)
                dismiss()
            }

            Button("Cancel", role: .cancel) { }
        } message: {
            Text(list.remoteAccessRole == .follower
                ? "This removes the followed list from your library."
                : "This removes the list from every route and deletes the list details.")
        }
    }

    @ViewBuilder
    private func listHeaderOverlay(routes: [RouteRecord]) -> some View {
        HStack(spacing: 12) {
            RouteVaultToolbarIconButton(
                systemImage: "map",
                accessibilityLabel: "Open list map",
                accessibilityIdentifier: "route-list-open-map"
            ) {
                isShowingMapBrowse = true
            }
            .disabled(routes.isEmpty)

            Menu {
                Section("View") {
                    Picker("Route View", selection: preferredDensityBinding) {
                        ForEach(AppRouteListDensity.allCases, id: \.self) { density in
                            Label(density.title, systemImage: density.symbolName)
                                .tag(density)
                        }
                    }
                }

                Section("Sharing") {
                    if list.remoteAccessRole?.isOwnedByCurrentAccount != false {
                        Button {
                            isShowingSharingSheet = true
                        } label: {
                            Label("Sharing & Collaboration", systemImage: "person.2")
                        }
                    }

                    Button {
                        copyBulletedListToClipboard(using: routes)
                    } label: {
                        Label("Copy Bulleted List", systemImage: "doc.on.clipboard")
                    }
                    .disabled(routes.isEmpty)
                }

                if list.canSyncRemotelyFromThisDevice {
                    Section("Edit") {
                        Button {
                            renameDraft = list.name
                            isShowingRenamePrompt = true
                        } label: {
                            Label("Edit Name", systemImage: "pencil")
                        }

                        Button {
                            descriptionDraft = list.listDescription
                            isShowingDescriptionEditor = true
                        } label: {
                            Label("Edit Description", systemImage: "text.alignleft")
                        }
                    }
                }

                Section("Offline") {
                    Button {
                        Task { await downloadFullListOffline(routes: routes) }
                } label: {
                    Label(
                        isDownloadingOffline
                            ? (offlineDownloadProgress?.buttonLabel ?? "Downloading Offline…")
                            : (routes.allSatisfy(\.hasOfflineAssets) ? "Refresh Full List Offline Files" : "Download Full List Offline Files"),
                        systemImage: "arrow.down.circle"
                    )
                }
                .accessibilityIdentifier("route-list-download-full-offline")
                .disabled(isDownloadingOffline || routes.isEmpty)
            }

                if list.remoteAccessRole == nil || list.remoteAccessRole == .owner || list.remoteAccessRole == .follower {
                    Section {
                        Button(role: .destructive) {
                            isShowingDeleteConfirmation = true
                        } label: {
                            Label(list.remoteAccessRole == .follower ? "Remove From Library" : "Delete List", systemImage: "trash")
                        }
                    }
                }
            } label: {
                RouteVaultToolbarIconGlyph(systemImage: "ellipsis")
                    .contentShape(Circle())
                    .accessibilityLabel("List settings")
                    .accessibilityIdentifier("route-list-settings-button")
            }
        }
        .allowsHitTesting(true)
    }

    private struct ContentSnapshot {
        let routes: [RouteRecord]
        let filteredRoutes: [RouteRecord]
        let offlineRouteCount: Int
        let missingImportedRoutes: [RouteListSharedRouteReference]
    }

    private var contentSnapshot: ContentSnapshot {
        let resolvedImportedRouteReferences = resolveRouteListReferences(list.importedRouteReferences, in: allRoutes)
        let resolvedImportedRouteIDs = Set(deduplicatedResolvedRoutes(resolvedImportedRouteReferences).map(\.stravaRouteID))
        let routes = allRoutes.filter {
            $0.hasList(named: list.name) || resolvedImportedRouteIDs.contains($0.stravaRouteID)
        }
        let filteredRoutes = libraryModel.filteredRoutes(from: routes)
        let offlineRouteCount = routes.filter(\.hasOfflineAssets).count
        let missingImportedRoutes = resolvedImportedRouteReferences.compactMap {
            $0.route == nil ? $0.reference : nil
        }
        return ContentSnapshot(
            routes: routes,
            filteredRoutes: filteredRoutes,
            offlineRouteCount: offlineRouteCount,
            missingImportedRoutes: missingImportedRoutes
        )
    }

    private var importedRouteRepairKey: String {
        var hasher = Hasher()
        hasher.combine(list.id)
        hasher.combine(list.name)
        for reference in list.importedRouteReferences {
            hasher.combine(reference.routeID)
            hasher.combine(reference.name)
        }
        for route in allRoutes {
            hasher.combine(route.stravaRouteID)
            hasher.combine(route.name)
            hasher.combine(route.hasList(named: list.name))
        }
        return String(hasher.finalize())
    }

    private var preferredDensity: AppRouteListDensity {
        list.preferredDensity
    }

    private var preferredDensityBinding: Binding<AppRouteListDensity> {
        Binding(
            get: { preferredDensity },
            set: { updatePreferredDensity($0) }
        )
    }

    private func repairImportedRouteMembershipsIfNeeded() {
        let resolvedRoutes = deduplicatedResolvedRoutes(resolveRouteListReferences(list.importedRouteReferences, in: allRoutes))
        guard !resolvedRoutes.isEmpty else {
            return
        }

        var didChange = false
        for route in resolvedRoutes where !route.hasList(named: list.name) {
            route.listNames = RouteRecord.normalizedLabels(route.listNames + [list.name])
            didChange = true
        }

        guard didChange else {
            return
        }

        list.touch()
        try? modelContext.save()
    }

    private func visibleBannerMessage(_ value: String?) -> String? {
        guard let message = value?.trimmed.nilIfEmpty else {
            return nil
        }

        if message.caseInsensitiveCompare("cancelled") == .orderedSame {
            return nil
        }

        return message
    }

    private func copyBulletedListToClipboard(using routes: [RouteRecord]) {
        guard !routes.isEmpty else {
            return
        }

        UIPasteboard.general.string = RouteListMarkdownExportBuilder.build(list: list, routes: routes)
        errorMessage = nil
        statusMessage = "Copied bulleted list to the clipboard."
    }

    private func renameList(to candidateName: String) {
        let trimmedName = candidateName.trimmed
        guard !trimmedName.isEmpty else {
            errorMessage = "List name can’t be empty."
            return
        }

        let originalName = list.name
        let normalizedNewName = trimmedName.routeLabelIdentifier
        let hasDuplicate = allLists.contains {
            $0.id != list.id && $0.normalizedName == normalizedNewName
        }

        guard !hasDuplicate else {
            errorMessage = "A different list already uses that name."
            return
        }

        if originalName.routeLabelIdentifier != normalizedNewName {
            for route in allRoutes where route.hasList(named: originalName) {
                route.listNames = route.renamingList(from: originalName, to: trimmedName)
            }

            libraryModel.selectedCollections = Set(
                libraryModel.selectedCollections.map {
                    $0.routeLabelIdentifier == originalName.routeLabelIdentifier ? trimmedName : $0
                }
            )
        }

        list.name = trimmedName
        persistListChanges(status: "Renamed list to \(trimmedName).")
        renameDraft = trimmedName
    }

    private func updateDescription(to description: String) {
        list.listDescription = description.trimmed
        descriptionDraft = list.listDescription
        persistListChanges(status: list.hasDescription ? "Updated list description." : "Removed list description.")
    }

    private func updatePreferredDensity(_ density: AppRouteListDensity) {
        guard list.preferredDensity != density else {
            return
        }

        list.preferredDensity = density
        persistListChanges(status: "List view set to \(density.title.lowercased()).")
    }

    private func persistListChanges(status: String? = nil) {
        list.touch()

        do {
            try modelContext.save()
            errorMessage = nil
            if let status {
                statusMessage = status
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func onDeleteRoute(_ route: RouteRecord) {
        selectedRoute = nil
        modelContext.delete(route)
        try? modelContext.save()
    }

    @MainActor
    private func downloadFullListOffline(routes: [RouteRecord]) async {
        guard !routes.isEmpty else {
            statusMessage = "This list doesn’t have any routes yet."
            return
        }

        guard !isDownloadingOffline else {
            statusMessage = "Offline files are already downloading for this list."
            return
        }

        isDownloadingOffline = true
        errorMessage = nil
        statusMessage = nil
        offlineDownloadProgress = nil
        defer {
            isDownloadingOffline = false
            offlineDownloadProgress = nil
        }

        var completed = 0
        var failures: [String] = []

        for route in routes {
            let routeName = route.name
            statusMessage = "Downloading \(routeName)…"

            do {
                let storedAssets = try await offlineDownloadCoordinator.storeOfflineBundle(
                    for: route,
                    progress: { progress in
                        Task { @MainActor in
                            offlineDownloadProgress = progress
                            let percentageSuffix = progress.percentageText.map { " \($0)" } ?? ""
                            statusMessage = "Downloading \(routeName)…\(percentageSuffix)"
                        }
                    }
                )
                route.offlineGPXRelativePath = storedAssets.gpxRelativePath
                route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
                route.offlineDownloadedAt = storedAssets.downloadedAt
                completed += 1
            } catch {
                failures.append("\(route.name): \(error.localizedDescription)")
            }
        }

        do {
            try modelContext.save()
        } catch {
            failures.append(error.localizedDescription)
        }

        if completed > 0 {
            statusMessage = completed == 1
                ? "Saved offline files for 1 route in this list."
                : "Saved offline files for \(completed) routes in this list."
        }

        if !failures.isEmpty {
            errorMessage = failures.count == 1
                ? failures[0]
                : "\(failures.count) routes could not be saved offline. \(failures[0])"
        }
    }
}

private struct MissingImportedRoutesPanel: View {
    let references: [RouteListSharedRouteReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Missing From This Device")
                .font(.headline)

            ForEach(references) { reference in
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Route ID \(reference.routeID)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .routePanelSurface(cornerRadius: 28)
    }
}

private struct RouteListDescriptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @State private var descriptionText: String
    let onSave: (String) -> Void

    init(title: String, initialDescription: String, onSave: @escaping (String) -> Void) {
        self.title = title
        _descriptionText = State(initialValue: initialDescription)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Description")
                .font(.headline)

            TextEditor(text: $descriptionText)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 180)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(20)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    onSave(descriptionText)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }
}

private enum RouteListMarkdownExportBuilder {
    static func build(list: RouteList, routes: [RouteRecord]) -> String {
        var lines: [String] = [
            "# \(list.name)",
            ""
        ]

        if let description = list.listDescription.trimmed.nilIfEmpty {
            lines.append(description)
            lines.append("")
        }

        if routes.isEmpty {
            lines.append("- No routes in this list yet.")
            return lines.joined(separator: "\n")
        }

        for route in routes {
            let details = [
                RouteDisplayFormatter.distance(route.distanceMeters),
                RouteDisplayFormatter.climb(route.elevationGainMeters),
                RouteDisplayFormatter.duration(route.estimatedMovingTime)
            ]
            .filter { !$0.isEmpty }

            var bullet = "- \(route.name)"
            if !details.isEmpty {
                bullet += " - \(details.joined(separator: " • "))"
            }
            lines.append(bullet)

            if let routeURL = route.routeURL?.absoluteString {
                lines.append("  \(routeURL)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

private struct DeletedRoutesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RouteLibraryModel

    var body: some View {
        Group {
            if model.deletedRoutes.isEmpty {
                ContentUnavailableView(
                    "No Deleted Routes",
                    systemImage: "trash.slash",
                    description: Text("Deleted Strava routes stay blocked from sync until you restore them here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.deletedRoutes.count > 1 {
                            Button("Undelete All", action: model.restoreAllDeletedRoutes)
                                .buttonStyle(.borderedProminent)
                        }

                        ForEach(model.deletedRoutes) { tombstone in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tombstone.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text("Deleted \(RouteDisplayFormatter.absoluteDate(tombstone.deletedAt))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Button("Undelete") {
                                    model.restoreDeletedRoute(tombstone)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                    .padding(20)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
        }
        .navigationTitle("Deleted Routes")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("deleted-routes-screen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }
}

private struct ConnectionSection: View {
    @Bindable var model: RouteLibraryModel

    private var isReconnectState: Bool {
        model.errorMessage?.localizedCaseInsensitiveContains("reconnect") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isReconnectState ? "Reconnect Strava" : "Connect Strava")
                        .font(.system(.title3, design: .rounded, weight: .bold))

                    Text(
                        isReconnectState
                            ? "Your previous Strava session is no longer valid. Reauthorize the account to resume route sync and exports."
                            : "This app uses its built-in Strava app configuration. The only user action is authorizing account access."
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "link.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color(red: 0.85, green: 0.36, blue: 0.18))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Redirect URI: \(model.redirectURI)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    Task { await model.connect() }
                } label: {
                    if model.isConnecting {
                        ProgressView()
                    } else {
                        Text(isReconnectState ? "Reconnect Strava" : "Connect Strava")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.36, blue: 0.18))
            }
        }
        .padding(20)
        .routePanelSurface(cornerRadius: 30)
    }
}

private struct ControlsSection: View {
    @Bindable var model: RouteLibraryModel
    let allRoutes: [RouteRecord]
    let lists: [RouteList]

    @State private var isShowingSortSheet = false
    @State private var isShowingFiltersSheet = false
    @State private var didApplyScreenshotPresentation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchField(
                text: $model.query,
                placeholder: "Search places, activities, lists"
            )
            .zIndex(0)

            HStack(spacing: 12) {
                ActionControlChip(
                    title: "Sort",
                    value: "",
                    symbolName: sortChipSymbolName,
                    isActive: model.hasCustomSortCriteria,
                    accessibilityIdentifier: "route-library-sort-button"
                ) {
                    isShowingSortSheet = true
                }

                ActionControlChip(
                    title: "Filters",
                    value: "",
                    symbolName: "line.3.horizontal.decrease.circle",
                    isActive: hasActiveFilterControls,
                    accessibilityIdentifier: "route-library-filters-button"
                ) {
                    isShowingFiltersSheet = true
                }
            }
            .zIndex(1)

            Text(controlsSummaryLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isShowingSortSheet) {
            NavigationStack {
                RouteSortSheet(model: model)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingFiltersSheet) {
            NavigationStack {
                RouteFiltersSheet(
                    model: model,
                    allRoutes: allRoutes,
                    lists: lists
                )
            }
            .presentationDetents([.large])
        }
        .onAppear {
            guard !didApplyScreenshotPresentation,
                  AppStoreScreenshotSupport.requestedShot == .sortOrder else {
                return
            }

            didApplyScreenshotPresentation = true
            model.sortCriteria = AppStoreScreenshotSupport.previewSortCriteria
            DispatchQueue.main.async {
                isShowingSortSheet = true
            }
        }
    }

    private var hasActiveFilterControls: Bool {
        !filterTokens.isEmpty
    }

    private var filtersChipValue: String {
        guard let firstToken = filterTokens.first else {
            return "All"
        }

        guard filterTokens.count == 1 else {
            return "\(filterTokens.count) active"
        }

        return "\(firstToken.title) · \(firstToken.value)"
    }

    private var controlsSummaryLine: String {
        "\(sortChipValue) · \(filtersSummaryLine)"
    }

    private var filtersSummaryLine: String {
        guard let firstToken = filterTokens.first else {
            return "All routes"
        }

        guard filterTokens.count == 1 else {
            return "\(filterTokens.count) filters active"
        }

        if firstToken.value.isEmpty {
            return firstToken.title
        }

        return "\(firstToken.title): \(firstToken.value)"
    }

    private var sortChipValue: String {
        if model.hasCustomSortCriteria {
            return sortCriteriaSummary
        }

        return RouteSortCriterion.defaultCriterion.option.title
    }

    private var sortChipSymbolName: String {
        model.sortCriteria.first?.option.symbolName ?? RouteSortCriterion.defaultCriterion.option.symbolName
    }

    private var appliedTokens: [AppliedFilterToken] {
        var tokens: [AppliedFilterToken] = []

        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tokens.append(
                AppliedFilterToken(
                    id: "query",
                    title: "Search",
                    value: model.query.trimmingCharacters(in: .whitespacesAndNewlines),
                    symbolName: "magnifyingglass",
                    clear: { model.query = "" }
                )
            )
        }

        if model.hasCustomSortCriteria {
            tokens.append(
                AppliedFilterToken(
                    id: "sort",
                    title: "Sort",
                    value: sortCriteriaSummary,
                    symbolName: model.sortCriteria.first?.option.symbolName ?? RouteSortCriterion.defaultCriterion.option.symbolName,
                    clear: {
                        model.sortCriteria = [.defaultCriterion]
                    }
                )
            )
        }

        if model.selectedMovements != [.all] {
            tokens.append(
                AppliedFilterToken(
                    id: "movement",
                    title: "Movement",
                    value: movementSummary,
                    symbolName: movementSymbolName,
                    clear: { model.selectedMovements = [.all] }
                )
            )
        }

        if model.selectedSports != [.all] {
            tokens.append(
                AppliedFilterToken(
                    id: "sport",
                    title: "Sport",
                    value: sportSummary,
                    symbolName: sportSymbolName,
                    clear: { model.selectedSports = [.all] }
                )
            )
        }

        if model.hasCustomDistanceRange {
            tokens.append(
                AppliedFilterToken(
                    id: "distance",
                    title: "Distance",
                    value: distanceFilterSummary,
                    symbolName: "ruler",
                    clear: clearDistanceFilter
                )
            )
        } else if model.selectedDistance != .all {
            tokens.append(
                AppliedFilterToken(
                    id: "distance-legacy",
                    title: "Distance",
                    value: model.selectedDistance.shortTitle,
                    symbolName: model.selectedDistance.symbolName,
                    clear: clearDistanceFilter
                )
            )
        }

        if model.hasCustomClimbRange {
            tokens.append(
                AppliedFilterToken(
                    id: "climb-range",
                    title: "Climb",
                    value: climbFilterSummary,
                    symbolName: "mountain.2",
                    clear: clearClimbFilter
                )
            )
        } else if model.selectedClimb != .all {
            tokens.append(
                AppliedFilterToken(
                    id: "climb-legacy",
                    title: "Climb",
                    value: model.selectedClimb.shortTitle,
                    symbolName: model.selectedClimb.symbolName,
                    clear: clearClimbFilter
                )
            )
        }

        if model.hasActiveStartFilter {
            let shouldClearReference = model.selectedStartFilterMode == .radius && !model.usesStartProximitySort
            tokens.append(
                AppliedFilterToken(
                    id: "start-filter",
                    title: model.selectedStartFilterMode.tokenTitle,
                    value: model.selectedStartFilterValue ?? "",
                    symbolName: model.selectedStartFilterMode.symbolName,
                    clear: {
                        model.clearStartFiltering()
                        if shouldClearReference {
                            model.clearSelectedStartLocation()
                        }
                    }
                )
            )
        }

        if model.usesStartProximitySort, model.hasSelectedStartLocation {
            tokens.append(
                AppliedFilterToken(
                    id: "start-reference",
                    title: "Reference",
                    value: model.selectedStartLocationDisplayName,
                    symbolName: "location.north.line",
                    clear: {
                        model.clearSelectedStartLocation()
                        model.clearStartProximitySorts()
                    }
                )
            )
        }

        if model.selectedSurfaceFilters != [.all] {
            tokens.append(
                AppliedFilterToken(
                    id: "surface",
                    title: "Surface",
                    value: surfaceSummary,
                    symbolName: surfaceSymbolName,
                    clear: { model.selectedSurfaceFilters = [.all] }
                )
            )
        }

        if !model.selectedCollections.isEmpty {
            tokens.append(
                AppliedFilterToken(
                    id: "list",
                    title: "Lists",
                    value: tagSummary,
                    symbolName: "list.bullet",
                    clear: { model.selectedCollections = [] }
                )
            )
        }

        if model.showOnlyOfflineRoutes {
            tokens.append(
                AppliedFilterToken(
                    id: "offline",
                    title: "Offline",
                    value: "Saved only",
                    symbolName: "arrow.down.circle.fill",
                    clear: { model.showOnlyOfflineRoutes = false }
                )
            )
        }

        return tokens
    }

    private var filterTokens: [AppliedFilterToken] {
        appliedTokens.filter { $0.id != "query" && $0.id != "sort" }
    }

    private var sortCriteriaSummary: String {
        let labels = model.sortCriteria.map { criterion in
            "\(criterion.option.shortTitle) \(criterion.direction == .descending ? "↓" : "↑")"
        }
        return joinedSummary(from: labels, fallback: "Recent ↓")
    }

    private var selectedMovements: [RouteMovementFilter] {
        RouteMovementFilter.allCases.filter { $0 != .all && model.selectedMovements.contains($0) }
    }

    private var selectedSports: [RouteSportFilter] {
        model.orderedSportFilters(from: allRoutes).filter { $0 != .all && model.selectedSports.contains($0) }
    }

    private var selectedSurfaceFilters: [RouteSurfaceFilter] {
        RouteSurfaceFilter.allCases.filter { $0 != .all && model.selectedSurfaceFilters.contains($0) }
    }

    private var movementSummary: String {
        joinedSummary(from: selectedMovements.map(\.shortTitle), fallback: RouteMovementFilter.all.shortTitle)
    }

    private var sportSummary: String {
        joinedSummary(from: selectedSports.map(\.shortTitle), fallback: RouteSportFilter.all.shortTitle)
    }

    private var surfaceSummary: String {
        joinedSummary(from: selectedSurfaceFilters.map(\.shortTitle), fallback: RouteSurfaceFilter.all.shortTitle)
    }

    private var tagSummary: String {
        joinedSummary(
            from: model.selectedCollections.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            fallback: "All"
        )
    }

    private var movementSymbolName: String {
        selectedMovements.first?.symbolName ?? RouteMovementFilter.all.symbolName
    }

    private var sportSymbolName: String {
        selectedSports.first?.symbolName ?? RouteSportFilter.all.symbolName
    }

    private var surfaceSymbolName: String {
        selectedSurfaceFilters.first?.symbolName ?? RouteSurfaceFilter.all.symbolName
    }

    private var distanceFilterSummary: String {
        switch (model.selectedDistanceMinimumMiles, model.selectedDistanceMaximumMiles) {
        case (nil, nil):
            return "Any distance"
        case let (minimumMiles?, maximumMiles?):
            return "\(RouteDisplayFormatter.distanceMiles(minimumMiles)) - \(RouteDisplayFormatter.distanceMiles(maximumMiles))"
        case let (minimumMiles?, nil):
            return "\(RouteDisplayFormatter.distanceMiles(minimumMiles))+"
        case let (nil, maximumMiles?):
            return "Up to \(RouteDisplayFormatter.distanceMiles(maximumMiles))"
        }
    }

    private func clearDistanceFilter() {
        model.selectedDistance = .all
        model.selectedDistanceMinimumMiles = nil
        model.selectedDistanceMaximumMiles = nil
    }

    private var climbFilterSummary: String {
        switch (model.selectedClimbMinimumFeet, model.selectedClimbMaximumFeet) {
        case (nil, nil):
            return "Any climb"
        case let (minimumFeet?, maximumFeet?):
            return "\(RouteDisplayFormatter.climbFeet(minimumFeet)) - \(RouteDisplayFormatter.climbFeet(maximumFeet))"
        case let (minimumFeet?, nil):
            return "\(RouteDisplayFormatter.climbFeet(minimumFeet))+"
        case let (nil, maximumFeet?):
            return "Up to \(RouteDisplayFormatter.climbFeet(maximumFeet))"
        }
    }

    private func clearClimbFilter() {
        model.selectedClimb = .all
        model.selectedClimbMinimumFeet = nil
        model.selectedClimbMaximumFeet = nil
    }

    private func joinedSummary(from labels: [String], fallback: String) -> String {
        guard !labels.isEmpty else {
            return fallback
        }

        if labels.count <= 2 {
            return labels.joined(separator: ", ")
        }

        return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2)"
    }
}

private struct RouteSortSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RouteLibraryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FilterPanel(
                    title: "Sort Order",
                    caption: ""
                ) {
                    SortPriorityPanel(
                        model: model,
                        hasSelectedStartLocation: model.hasSelectedStartLocation
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle("Sort Order")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("route-sort-screen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }

            if model.hasCustomSortCriteria {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") {
                        model.sortCriteria = [.defaultCriterion]
                    }
                }
            }
        }
    }
}

private struct RouteFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: RouteLibraryModel
    let allRoutes: [RouteRecord]
    let lists: [RouteList]

    @State private var isShowingStartLocationPicker = false
    @State private var startLocationDraft = ""
    @State private var startLocationResults: [StartLocationSearchResult] = []
    @State private var isSearchingStartLocations = false
    @State private var isKeyboardVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FilterPanel(
                    title: "Activity",
                    caption: ""
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        FilterNavigationRow(
                            title: "Movement",
                            summary: movementSummary,
                            symbolName: selectedMovementSymbolName,
                            isActive: model.selectedMovements != [.all]
                        ) {
                            FilterOptionSelectionScreen(
                                title: "Movement",
                                descriptionText: "Choose one or more high-level movement types.",
                                options: RouteMovementFilter.allCases,
                                isSelected: { model.selectedMovements.contains($0) },
                                action: { model.toggleMovementSelection($0) },
                                titleForOption: { $0.title },
                                symbolNameForOption: { $0.symbolName }
                            )
                        }

                        FilterNavigationRow(
                            title: "Sport",
                            summary: sportSummary,
                            symbolName: selectedSportSymbolName,
                            isActive: model.selectedSports != [.all]
                        ) {
                            FilterOptionSelectionScreen(
                                title: "Sport",
                                descriptionText: sportDescriptionText,
                                options: availableSportFilters,
                                isSelected: { model.selectedSports.contains($0) },
                                action: { model.toggleSportSelection($0) },
                                titleForOption: { $0.title },
                                symbolNameForOption: { $0.symbolName }
                            )
                        }

                        FilterNavigationRow(
                            title: "Surface",
                            summary: surfaceSummary,
                            symbolName: selectedSurfaceSymbolName,
                            isActive: model.selectedSurfaceFilters != [.all]
                        ) {
                            FilterOptionSelectionScreen(
                                title: "Surface",
                                descriptionText: "Filter by surface profile using the route classification from Strava or GPX import.",
                                options: RouteSurfaceFilter.allCases,
                                isSelected: { model.selectedSurfaceFilters.contains($0) },
                                action: { model.toggleSurfaceSelection($0) },
                                titleForOption: { $0.title },
                                symbolNameForOption: { $0.symbolName }
                            )
                        }
                    }
                }

                FilterPanel(
                    title: "Ranges",
                    caption: ""
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        DistanceRangePanel(
                            model: model,
                            sliderBounds: distanceSliderBounds,
                            filteredBounds: filteredDistanceBounds
                        )

                        Divider()
                            .overlay(Color.primary.opacity(0.08))
                            .padding(.vertical, 2)

                        ClimbRangePanel(
                            model: model,
                            sliderBounds: climbSliderBounds,
                            filteredBounds: filteredClimbBounds
                        )
                    }
                }

                FilterPanel(
                    title: "Start Areas",
                    caption: ""
                ) {
                    StartLocationFilterBox(
                        selectedValues: model.selectedStartTextFilters,
                        activeRadiusSummary: model.selectedStartFilterMode == .radius ? model.selectedStartFilterValue : nil,
                        activeRadiusReferenceName: model.selectedStartFilterMode == .radius ? model.selectedStartLocationDisplayName : nil,
                        draft: $startLocationDraft,
                        searchResults: startLocationResults,
                        isSearching: isSearchingStartLocations,
                        onSelectSearchResult: selectStartLocationResult,
                        onRemoveValue: model.removeStartTextFilter,
                        onChooseOnMap: { isShowingStartLocationPicker = true },
                        onClearRadius: {
                            model.clearStartFiltering()
                            if !model.usesStartProximitySort {
                                model.clearSelectedStartLocation()
                            }
                        }
                    )
                }

                FilterPanel(
                    title: "Lists",
                    caption: ""
                ) {
                    InlineListFilterBox(
                        lists: lists,
                        selectedTags: model.selectedCollections,
                        onToggle: model.toggleCollectionSelection
                    )
                }

                FilterPanel(
                    title: "Availability",
                    caption: ""
                ) {
                    FilterToggleRow(
                        title: "Offline",
                        summary: "Only routes saved for offline use",
                        symbolName: "arrow.down.circle.fill",
                        isOn: $model.showOnlyOfflineRoutes
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("route-filters-screen")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }

            if hasActiveControls {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset", action: resetControls)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isKeyboardVisible {
                HStack {
                    Spacer(minLength: 0)

                    Button("Done") {
                        dismissKeyboard()
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $isShowingStartLocationPicker) {
            NavigationStack {
                RouteStartLocationSheet(model: model)
            }
            .presentationDetents([.large])
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .task(id: startLocationDraft) {
            await refreshStartLocationResults()
        }
    }

    private var hasActiveControls: Bool {
        model.selectedMovements != [.all] ||
        model.selectedSports != [.all] ||
            model.hasCustomDistanceRange ||
            model.selectedDistance != .all ||
            model.hasCustomClimbRange ||
            model.selectedClimb != .all ||
            model.selectedSurfaceFilters != [.all] ||
            !model.selectedCollections.isEmpty ||
            model.showOnlyOfflineRoutes ||
            model.hasActiveStartFilter
    }

    private var availableSportFilters: [RouteSportFilter] {
        model.orderedSportFilters(from: allRoutes)
    }

    private var movementSummary: String {
        selectionSummary(
            for: RouteMovementFilter.allCases.filter { $0 != .all && model.selectedMovements.contains($0) }
                .map(\.title),
            fallback: RouteMovementFilter.all.title
        )
    }

    private var sportSummary: String {
        selectionSummary(
            for: model.orderedSportFilters(from: allRoutes).filter { $0 != .all && model.selectedSports.contains($0) }
                .map(\.title),
            fallback: RouteSportFilter.all.title
        )
    }

    private var surfaceSummary: String {
        selectionSummary(
            for: RouteSurfaceFilter.allCases.filter { $0 != .all && model.selectedSurfaceFilters.contains($0) }
                .map(\.title),
            fallback: RouteSurfaceFilter.all.title
        )
    }

    private var sportDescriptionText: String {
        if model.selectedMovements == [.all] {
            return "Choose one or more specific sport types."
        }

        return "Available sports follow the current movement filter, so only compatible sport types appear here."
    }

    private var selectedMovementSymbolName: String {
        RouteMovementFilter.allCases.first(where: { $0 != .all && model.selectedMovements.contains($0) })?.symbolName
            ?? RouteMovementFilter.all.symbolName
    }

    private var selectedSportSymbolName: String {
        model.orderedSportFilters(from: allRoutes).first(where: { $0 != .all && model.selectedSports.contains($0) })?.symbolName
            ?? RouteSportFilter.all.symbolName
    }

    private var selectedSurfaceSymbolName: String {
        RouteSurfaceFilter.allCases.first(where: { $0 != .all && model.selectedSurfaceFilters.contains($0) })?.symbolName
            ?? RouteSurfaceFilter.all.symbolName
    }

    private var distanceReferenceRoutes: [RouteRecord] {
        model.routesMatchingNonDistanceFilters(from: allRoutes)
    }

    private var filteredDistanceBounds: ClosedRange<Double>? {
        let distances = distanceReferenceRoutes.map { $0.distanceMeters * 0.000621371 }

        guard let minimumDistanceMiles = distances.min(),
              let maximumDistanceMiles = distances.max() else {
            return nil
        }

        return minimumDistanceMiles ... maximumDistanceMiles
    }

    private var distanceSliderBounds: ClosedRange<Double> {
        guard let filteredDistanceBounds else {
            return 0.0 ... 10.0
        }

        let lowerBound = floor(filteredDistanceBounds.lowerBound)
        let upperBound = ceil(filteredDistanceBounds.upperBound)
        return lowerBound ... max(lowerBound + 1, upperBound)
    }

    private var climbReferenceRoutes: [RouteRecord] {
        model.routesMatchingNonClimbFilters(from: allRoutes)
    }

    private var filteredClimbBounds: ClosedRange<Double>? {
        let climbs = climbReferenceRoutes.map { $0.elevationGainMeters * 3.28084 }

        guard let minimumClimbFeet = climbs.min(),
              let maximumClimbFeet = climbs.max() else {
            return nil
        }

        return minimumClimbFeet ... maximumClimbFeet
    }

    private var climbSliderBounds: ClosedRange<Double> {
        guard let filteredClimbBounds else {
            return 0.0 ... 500.0
        }

        let lowerBound = floor(filteredClimbBounds.lowerBound / 100) * 100
        let upperBound = ceil(filteredClimbBounds.upperBound / 100) * 100
        return lowerBound ... max(lowerBound + 100, upperBound)
    }

    private var distanceFilterSummary: String {
        switch (model.selectedDistanceMinimumMiles, model.selectedDistanceMaximumMiles) {
        case (nil, nil):
            return "Any distance"
        case let (minimumMiles?, maximumMiles?):
            return "\(RouteDisplayFormatter.distanceMiles(minimumMiles)) - \(RouteDisplayFormatter.distanceMiles(maximumMiles))"
        case let (minimumMiles?, nil):
            return "\(RouteDisplayFormatter.distanceMiles(minimumMiles))+"
        case let (nil, maximumMiles?):
            return "Up to \(RouteDisplayFormatter.distanceMiles(maximumMiles))"
        }
    }

    private var climbFilterSummary: String {
        switch (model.selectedClimbMinimumFeet, model.selectedClimbMaximumFeet) {
        case (nil, nil):
            return "Any climb"
        case let (minimumFeet?, maximumFeet?):
            return "\(RouteDisplayFormatter.climbFeet(minimumFeet)) - \(RouteDisplayFormatter.climbFeet(maximumFeet))"
        case let (minimumFeet?, nil):
            return "\(RouteDisplayFormatter.climbFeet(minimumFeet))+"
        case let (nil, maximumFeet?):
            return "Up to \(RouteDisplayFormatter.climbFeet(maximumFeet))"
        }
    }

    private func resetControls() {
        model.selectedMovements = [.all]
        model.selectedSports = [.all]
        model.selectedDistance = .all
        model.selectedDistanceMinimumMiles = nil
        model.selectedDistanceMaximumMiles = nil
        model.selectedClimb = .all
        model.selectedClimbMinimumFeet = nil
        model.selectedClimbMaximumFeet = nil
        model.selectedSurfaceFilters = [.all]
        model.selectedCollections = []
        model.showOnlyOfflineRoutes = false
        model.clearStartTextFilters()
        model.clearStartFiltering()
        if !model.usesStartProximitySort {
            model.clearSelectedStartLocation()
        }
        model.selectedStartLocationRadiusMiles = 25.0
        startLocationDraft = ""
        startLocationResults = []
    }

    private func selectStartLocationResult(_ result: StartLocationSearchResult) {
        model.addStartTextFilters(from: result.selectionValue)
        startLocationDraft = ""
        startLocationResults = []
    }

    private func refreshStartLocationResults() async {
        let trimmedDraft = startLocationDraft.trimmed
        guard trimmedDraft.count >= 2 else {
            await MainActor.run {
                isSearchingStartLocations = false
                startLocationResults = []
            }
            return
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            isSearchingStartLocations = true
        }

        defer {
            Task { @MainActor in
                isSearchingStartLocations = false
            }
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedDraft

        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.compactMap(StartLocationSearchResult.init)
            let deduplicated = deduplicatedStartLocationResults(results)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                startLocationResults = deduplicated
            }
        } catch {
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                startLocationResults = []
            }
        }
    }

    private func deduplicatedStartLocationResults(_ results: [StartLocationSearchResult]) -> [StartLocationSearchResult] {
        var seen = Set<String>()
        var deduplicated: [StartLocationSearchResult] = []

        for result in results {
            let token = result.selectionValue.routeLocationToken
            guard !token.isEmpty, seen.insert(token).inserted else {
                continue
            }

            deduplicated.append(result)
        }

        return Array(deduplicated.prefix(8))
    }

    private func selectionSummary(for labels: [String], fallback: String) -> String {
        guard !labels.isEmpty else {
            return fallback
        }

        if labels.count <= 2 {
            return labels.joined(separator: ", ")
        }

        return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2)"
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct RouteResultsSection: View {
    let filteredRoutes: [RouteRecord]
    let allLists: [RouteList]
    let routeCount: Int
    let density: AppRouteListDensity
    let hasActiveFilters: Bool
    let isSyncing: Bool
    let onResetFilters: () -> Void
    let onDeleteRoute: (RouteRecord) -> Void
    let onToggleRouteList: (RouteRecord, RouteList) -> Void
    let onReportStatus: (String) -> Void
    let onReportError: (String) -> Void
    let onSelect: (RouteRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasActiveFilters {
                HStack {
                    Spacer(minLength: 0)

                    Button("Clear Filters", action: onResetFilters)
                        .font(.subheadline.weight(.semibold))
                }
            }

            if filteredRoutes.isEmpty {
                ContentUnavailableView {
                    Label("No Routes Yet", systemImage: "map")
                } description: {
                    Text(isSyncing ? "Strava sync is in progress." : "Pull your routes from Strava or loosen the current filters.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .routePanelSurface(cornerRadius: 30)
            } else {
                LazyVStack(spacing: density.stackSpacing) {
                    ForEach(filteredRoutes) { route in
                        RouteLibraryResultRow(
                            route: route,
                            allLists: allLists,
                            density: density,
                            onDeleteRoute: onDeleteRoute,
                            onToggleRouteList: onToggleRouteList,
                            onReportStatus: onReportStatus,
                            onReportError: onReportError
                        ) {
                            onSelect(route)
                        }
                    }
                }
            }
        }
    }

}

@MainActor
private struct RouteOfflineDownloadCoordinator {
    private let routeDetailDownloadCoordinator = RouteDetailDownloadCoordinator()
    private let offlineAssetService = RouteOfflineAssetService()

    func storeOfflineBundle(
        for route: RouteRecord,
        progress: (@Sendable (RouteOfflineDownloadProgress) -> Void)? = nil
    ) async throws -> RouteOfflineAssetFiles {
        try await routeDetailDownloadCoordinator.downloadRouteDetails(
            for: route,
            selection: preferredSelection(for: route),
            progress: progress
        )
    }

    private func preferredSelection(for route: RouteRecord) -> RouteOfflineDownloadSelection {
        let offlineStatus = offlineAssetService.offlineStatus(for: route)
        let hasConcreteAssets = offlineStatus.hasConcreteAssets
        let selectedMapStyles = hasConcreteAssets ? offlineStatus.mapStyles : [.outdoors]

        return RouteOfflineDownloadSelection(
            includesGPX: hasConcreteAssets ? (offlineStatus.hasGPX || !selectedMapStyles.isEmpty) : true,
            mapStyles: selectedMapStyles,
            includesTerrain: hasConcreteAssets ? (offlineStatus.includesTerrain && !selectedMapStyles.isEmpty) : false
        )
    }
}

private struct RouteLibraryResultRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    let route: RouteRecord
    let allLists: [RouteList]
    let density: AppRouteListDensity
    let onDeleteRoute: (RouteRecord) -> Void
    let onToggleRouteList: (RouteRecord, RouteList) -> Void
    let onReportStatus: (String) -> Void
    let onReportError: (String) -> Void
    let onSelect: () -> Void

    private let offlineAssetService = RouteOfflineAssetService()
    private let offlineDownloadCoordinator = RouteOfflineDownloadCoordinator()
    @State private var isShowingCreateListSheet = false
    @State private var isDownloadingOffline = false

    private var offlineStatus: RouteOfflineAssetStatus {
        offlineAssetService.offlineStatus(for: route)
    }

    var body: some View {
        SwipeRevealRow(
            leadingActions: leadingSwipeActions,
            trailingActions: trailingSwipeActions
        ) {
            RouteCardView(route: route, density: density, onSelect: onSelect)
                .contextMenu {
                    quickActionMenu
                }
                .sheet(isPresented: $isShowingCreateListSheet) {
                    NavigationStack {
                        QuickCreateListSheet { listName in
                            createListAndAddRoute(named: listName)
                        }
                    }
                    .presentationDetents([.medium])
                }
            }
    }

    private var leadingSwipeActions: [SwipeRevealAction] {
        var actions: [SwipeRevealAction] = []

        if offlineStatus.hasConcreteAssets {
            actions.append(
                SwipeRevealAction(
                    title: "Remove",
                    systemImage: "trash",
                    tint: .red,
                    isEnabled: !isDownloadingOffline
                ) {
                    removeOfflineDownload()
                }
            )
        } else {
            actions.append(
                SwipeRevealAction(
                    title: isDownloadingOffline ? "Saving" : "Download",
                    systemImage: "arrow.down.circle",
                    tint: .blue,
                    accessibilityIdentifier: "route-library-swipe-download-\(route.stravaRouteID)",
                    isEnabled: !isDownloadingOffline
                ) {
                    Task { await downloadOfflineBundle() }
                }
            )
        }

        if route.startCoordinate != nil {
            actions.append(
                SwipeRevealAction(
                    title: "Navigate",
                    systemImage: "location.fill.viewfinder",
                    tint: .green
                ) {
                    openStartInMaps()
                }
            )
        }

        return actions
    }

    private var trailingSwipeActions: [SwipeRevealAction] {
        [
            SwipeRevealAction(
                title: "Delete",
                systemImage: "trash",
                tint: .red
            ) {
                onDeleteRoute(route)
            }
        ]
    }

    @ViewBuilder
    private var quickActionMenu: some View {
        if let routeURL = route.routeURL {
            Button {
                openURL(routeURL)
            } label: {
                Label("Open in Strava", systemImage: "arrow.up.right.square")
            }
        }

        if route.startCoordinate != nil {
            Button {
                openStartInMaps()
            } label: {
                Label("Route to Start", systemImage: "location.fill.viewfinder")
            }
        }

        if offlineStatus.hasConcreteAssets {
            Button(role: .destructive) {
                removeOfflineDownload()
            } label: {
                Label("Remove Offline Files", systemImage: "trash")
            }
            .accessibilityIdentifier("route-library-menu-remove-\(route.stravaRouteID)")
            .disabled(isDownloadingOffline)
        } else {
            Button {
                Task { await downloadOfflineBundle() }
            } label: {
                Label(isDownloadingOffline ? "Downloading Offline Files" : "Download Offline Files", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("route-library-menu-download-\(route.stravaRouteID)")
            .disabled(isDownloadingOffline)
        }

        Menu {
            Button {
                isShowingCreateListSheet = true
            } label: {
                Label("New List…", systemImage: "plus")
            }

            if allLists.isEmpty {
                Button("No lists yet") { }
                    .disabled(true)
            } else {
                Divider()

                ForEach(allLists) { list in
                    Button {
                        toggleList(list)
                    } label: {
                        if route.hasList(named: list.name) {
                            Label(list.name, systemImage: "checkmark")
                        } else {
                            Text(list.name)
                        }
                    }
                }
            }
        } label: {
            Label("Add to List", systemImage: "list.bullet")
        }

        Button(role: .destructive) {
            onDeleteRoute(route)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func toggleList(_ list: RouteList) {
        onToggleRouteList(route, list)
    }

    private func createListAndAddRoute(named listName: String) {
        let trimmedListName = listName.trimmed
        guard !trimmedListName.isEmpty else {
            onReportError("Enter a list name first.")
            return
        }

        if let existingList = allLists.first(where: { $0.normalizedName == trimmedListName.routeLabelIdentifier }) {
            toggleList(existingList)
            onReportStatus("Added \(route.name) to \(existingList.name).")
            return
        }

        let newList = RouteList(name: trimmedListName)
        modelContext.insert(newList)
        onToggleRouteList(route, newList)
        try? modelContext.save()
        onReportStatus("Created \(newList.name) and added \(route.name).")
    }

    private func openStartInMaps() {
        guard let coordinate = route.startCoordinate else {
            return
        }

        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = route.name
        mapItem.openInMaps(launchOptions: nil)
    }

    @MainActor
    private func downloadOfflineBundle() async {
        guard !isDownloadingOffline else {
            return
        }

        isDownloadingOffline = true
        defer { isDownloadingOffline = false }

        do {
            let storedAssets = try await offlineDownloadCoordinator.storeOfflineBundle(for: route)
            route.offlineGPXRelativePath = storedAssets.gpxRelativePath
            route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
            route.offlineDownloadedAt = storedAssets.downloadedAt
            try? modelContext.save()
            onReportStatus("Saved offline files for \(route.name).")
        } catch {
            onReportError(error.localizedDescription)
        }
    }

    private func removeOfflineDownload() {
        guard !isDownloadingOffline else {
            return
        }

        do {
            try offlineAssetService.removeOfflineAssets(for: route)
            route.offlineGPXRelativePath = nil
            route.offlineMapSnapshotRelativePath = nil
            route.offlineDownloadedAt = nil
            try? modelContext.save()
            onReportStatus("Removed offline files for \(route.name).")
        } catch {
            onReportError(error.localizedDescription)
        }
    }
}

private struct SwipeRevealAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let tint: Color
    var accessibilityIdentifier: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void
}

private struct SwipeRevealRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let leadingActions: [SwipeRevealAction]
    let trailingActions: [SwipeRevealAction]
    @ViewBuilder let content: () -> Content

    @State private var settledOffset: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    private let actionWidth: CGFloat = 92
    private let swipeAnimation = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.84)

    private var visibleOffset: CGFloat {
        clampOffset(settledOffset + dragTranslation)
    }

    private var leadingWidth: CGFloat {
        CGFloat(leadingActions.count) * actionWidth
    }

    private var trailingWidth: CGFloat {
        CGFloat(trailingActions.count) * actionWidth
    }

    var body: some View {
        ZStack {
            if !leadingActions.isEmpty, visibleOffset > 8 {
                HStack(spacing: 0) {
                    ForEach(leadingActions) { action in
                        SwipeRevealActionButton(action: action)
                            .frame(width: actionWidth)
                    }

                    Spacer(minLength: 0)
                }
            }

            if !trailingActions.isEmpty, visibleOffset < -8 {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ForEach(trailingActions) { action in
                        SwipeRevealActionButton(action: action)
                            .frame(width: actionWidth)
                    }
                }
            }

            content()
                .background(rowBackground)
                .offset(x: visibleOffset)

            if abs(visibleOffset) > 8 {
                Color.clear
                    .contentShape(Rectangle())
                    .offset(x: visibleOffset)
                    .onTapGesture {
                        withAnimation(swipeAnimation) {
                            settledOffset = 0
                        }
                    }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .highPriorityGesture(dragGesture)
        .animation(swipeAnimation, value: settledOffset)
    }

    private var rowBackground: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.black : Color.white.opacity(0.96))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                let proposedOffset = clampOffset(settledOffset + value.translation.width)
                let predictedOffset = clampOffset(settledOffset + value.predictedEndTranslation.width)

                withAnimation(swipeAnimation) {
                    settledOffset = targetOffset(
                        proposedOffset: proposedOffset,
                        predictedOffset: predictedOffset
                    )
                }
            }
    }

    private func clampOffset(_ value: CGFloat) -> CGFloat {
        min(max(value, -trailingWidth), leadingWidth)
    }

    private func targetOffset(proposedOffset: CGFloat, predictedOffset: CGFloat) -> CGFloat {
        let leadingThreshold = max(actionWidth * 0.45, leadingWidth * 0.4)
        let trailingThreshold = max(actionWidth * 0.45, trailingWidth * 0.4)

        if proposedOffset > 0, !leadingActions.isEmpty {
            return max(proposedOffset, predictedOffset) > leadingThreshold ? leadingWidth : 0
        }

        if proposedOffset < 0, !trailingActions.isEmpty {
            return min(proposedOffset, predictedOffset) < -trailingThreshold ? -trailingWidth : 0
        }

        return 0
    }
}

private struct SwipeRevealActionButton: View {
    let action: SwipeRevealAction

    var body: some View {
        Button {
            action.action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18, weight: .semibold))

                Text(action.title)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(action.tint.gradient)
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .accessibilityIdentifier(action.accessibilityIdentifier ?? "")
    }
}

private struct QuickCreateListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var listName = ""

    let onCreate: (String) -> Void

    var body: some View {
        Form {
            Section("New List") {
                TextField("List name", text: $listName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle("New List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Create") {
                    onCreate(listName)
                    dismiss()
                }
                .fontWeight(.semibold)
                .disabled(listName.trimmed.isEmpty)
            }
        }
    }
}

private enum RouteLibraryActivityState {
    case connecting
    case syncing
    case syncingProgress(completed: Int, total: Int, isEstimated: Bool)
    case importingGPX
    case syncingAndImporting
    case syncingAndImportingProgress(completed: Int, total: Int, isEstimated: Bool)
    case indexingStartLocations(completed: Int, total: Int)

    var symbolName: String {
        switch self {
        case .connecting:
            return "link.badge.plus"
        case .syncing:
            return "arrow.trianglehead.2.clockwise"
        case .syncingProgress:
            return "arrow.trianglehead.2.clockwise"
        case .importingGPX:
            return "square.and.arrow.down.on.square"
        case .syncingAndImporting:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .syncingAndImportingProgress:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .indexingStartLocations:
            return "magnifyingglass.circle"
        }
    }

    var title: String {
        switch self {
        case .connecting:
            return "Connecting Strava"
        case .syncing:
            return "Syncing Route Library"
        case .syncingProgress:
            return "Syncing Route Library"
        case .importingGPX:
            return "Importing GPX Routes"
        case .syncingAndImporting:
            return "Refreshing Local Library"
        case .syncingAndImportingProgress:
            return "Refreshing Local Library"
        case .indexingStartLocations:
            return "Indexing Start Locations"
        }
    }

    var message: String {
        switch self {
        case .connecting:
            return "Finishing authorization and preparing access to your routes."
        case .syncing:
            return "Pulling the latest routes from Strava. You can keep browsing while the library refreshes."
        case let .syncingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated)) routes downloaded from Strava so far. You can keep browsing while the library refreshes."
        case .importingGPX:
            return "Parsing files, deriving start locations, and saving routes locally."
        case .syncingAndImporting:
            return "Strava sync and GPX import are both running. The route list will refresh as work completes."
        case let .syncingAndImportingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated)) routes downloaded from Strava while GPX import also runs."
        case let .indexingStartLocations(completed, total):
            return "\(completed.formatted())/\(max(total, 1).formatted()) routes indexed for better search and start-area filtering."
        }
    }

    var progress: (completed: Int, total: Int)? {
        switch self {
        case let .syncingProgress(completed, total, _):
            return (completed, max(total, 1))
        case let .syncingAndImportingProgress(completed, total, _):
            return (completed, max(total, 1))
        case let .indexingStartLocations(completed, total):
            return (completed, max(total, 1))
        case .connecting, .syncing, .importingGPX, .syncingAndImporting:
            return nil
        }
    }

    var progressLabel: String? {
        switch self {
        case let .syncingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated))"
        case let .syncingAndImportingProgress(completed, total, isEstimated):
            return "\(completed.formatted())/\(totalProgressLabelValue(total, isEstimated: isEstimated))"
        case let .indexingStartLocations(completed, total):
            return "\(completed.formatted())/\(max(total, 1).formatted())"
        case .connecting, .syncing, .importingGPX, .syncingAndImporting:
            return nil
        }
    }

    private func totalProgressLabelValue(_ total: Int, isEstimated: Bool) -> String {
        let formattedTotal = max(total, 1).formatted()
        return isEstimated ? "\(formattedTotal)+" : formattedTotal
    }
}

private struct LibraryActivityBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: RouteLibraryActivityState

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    .frame(width: 38, height: 38)

                Image(systemName: state.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Text(state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let progress = state.progress {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(state.progressLabel ?? "\(progress.completed.formatted())/\(progress.total.formatted())")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .tint(accent)
                        .frame(width: 88)
                }
                .padding(.top, 2)
            } else {
                ProgressView()
                    .tint(accent)
                    .controlSize(.regular)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var accent: Color {
        Color(red: 0.93, green: 0.45, blue: 0.20)
    }

    private var background: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.13, blue: 0.10)
            : Color(red: 0.98, green: 0.93, blue: 0.89)
    }

    private var border: Color {
        accent.opacity(colorScheme == .dark ? 0.25 : 0.18)
    }
}

private struct DisconnectedEmptyState: View {
    let isImportingGPX: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Once Strava is connected, this screen becomes the full route workspace.")
                .font(.system(.title3, design: .rounded, weight: .bold))

            Text(descriptionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .routePanelSurface(cornerRadius: 28)
    }

    private var descriptionText: String {
        if isImportingGPX {
            return "GPX import is in progress. Starting locations are derived from the first route point in each file."
        }

        return "You can sync the athlete’s routes from Strava or import GPX files from the top-right menu, then search by start location, sort by distance or climbing, and manage local collections without leaving this page."
    }
}

private struct BannerView: View {
    @Environment(\.colorScheme) private var colorScheme
    enum Tone {
        case success
        case error
    }

    let message: String
    let tone: Tone

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .success:
            return Color(red: 0.20, green: 0.42, blue: 0.22)
        case .error:
            return Color(red: 0.62, green: 0.18, blue: 0.18)
        }
    }

    private var background: Color {
        switch tone {
        case .success:
            return colorScheme == .dark
                ? Color(red: 0.10, green: 0.24, blue: 0.15)
                : Color(red: 0.88, green: 0.95, blue: 0.88)
        case .error:
            return colorScheme == .dark
                ? Color(red: 0.28, green: 0.12, blue: 0.13)
                : Color(red: 0.98, green: 0.90, blue: 0.90)
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(text.isEmpty ? .clear : Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    text.isEmpty ? Color.primary.opacity(0.08) : Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.26),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct FilterPanel<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                if let caption = caption.nilIfEmpty {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(16)
        .routePanelSurface(cornerRadius: 28)
    }
}

private struct AdaptiveControlGrid<Content: View>: View {
    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 250), spacing: 10)]
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            content()
        }
    }
}

private enum RangeEndpointField {
    case minimum
    case maximum
}

private struct DistanceRangePanel: View {
    @Bindable var model: RouteLibraryModel
    let sliderBounds: ClosedRange<Double>
    let filteredBounds: ClosedRange<Double>?
    @State private var editingField: RangeEndpointField?
    @State private var minimumDraft = ""
    @State private var maximumDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("DISTANCE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 0)

                if model.hasCustomDistanceRange || model.selectedDistance != .all {
                    Button("Reset", action: resetDistance)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                EditableRangeEndpointPill(
                    title: "Min",
                    placeholder: "No minimum",
                    displayValue: minimumLabel,
                    unitLabel: RouteDisplayFormatter.measurementSystem.distanceUnitLabel,
                    draft: $minimumDraft,
                    isActive: model.selectedDistanceMinimumMiles != nil || editingField == .minimum,
                    isEditing: editingField == .minimum,
                    keyboardType: .decimalPad,
                    onTap: { beginEditing(.minimum) },
                    onFinishEditing: { finishEditing(.minimum) }
                )
                EditableRangeEndpointPill(
                    title: "Max",
                    placeholder: "No maximum",
                    displayValue: maximumLabel,
                    unitLabel: RouteDisplayFormatter.measurementSystem.distanceUnitLabel,
                    draft: $maximumDraft,
                    isActive: model.selectedDistanceMaximumMiles != nil || editingField == .maximum,
                    isEditing: editingField == .maximum,
                    keyboardType: .decimalPad,
                    onTap: { beginEditing(.maximum) },
                    onFinishEditing: { finishEditing(.maximum) }
                )
            }

            DualHandleRangeSlider(
                lowerValue: minimumBinding,
                upperValue: maximumBinding,
                bounds: displaySliderBounds,
                step: RouteDisplayFormatter.distanceSliderStep,
                isEnabled: hasReferenceRoutes,
                accessibilityLabel: "Distance range",
                accessibilityValue: summary
            )
        }
        .toolbar {
            if let editingField {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Clear") {
                        clear(field: editingField)
                    }

                    Spacer()

                    Button("Done") {
                        finishEditing(editingField)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var currentMinimumMiles: Double {
        min(
            max(model.selectedDistanceMinimumMiles ?? sliderBounds.lowerBound, sliderBounds.lowerBound),
            currentMaximumMiles
        )
    }

    private var currentMaximumMiles: Double {
        max(
            min(model.selectedDistanceMaximumMiles ?? sliderBounds.upperBound, sliderBounds.upperBound),
            sliderBounds.lowerBound
        )
    }

    private var currentMinimumDisplayDistance: Double {
        RouteDisplayFormatter.distanceDisplayValue(forMiles: currentMinimumMiles)
    }

    private var currentMaximumDisplayDistance: Double {
        RouteDisplayFormatter.distanceDisplayValue(forMiles: currentMaximumMiles)
    }

    private var displaySliderBounds: ClosedRange<Double> {
        RouteDisplayFormatter.distanceDisplayValue(forMiles: sliderBounds.lowerBound) ... RouteDisplayFormatter.distanceDisplayValue(forMiles: sliderBounds.upperBound)
    }

    private var hasReferenceRoutes: Bool {
        filteredBounds != nil
    }

    private var minimumLabel: String {
        if let selectedMinimum = model.selectedDistanceMinimumMiles {
            return RouteDisplayFormatter.distanceMiles(selectedMinimum)
        }

        if let filteredBounds {
            return RouteDisplayFormatter.distanceMiles(filteredBounds.lowerBound)
        }

        return RouteDisplayFormatter.distanceMiles(sliderBounds.lowerBound)
    }

    private var maximumLabel: String {
        if let selectedMaximum = model.selectedDistanceMaximumMiles {
            return RouteDisplayFormatter.distanceMiles(selectedMaximum)
        }

        if let filteredBounds {
            return RouteDisplayFormatter.distanceMiles(filteredBounds.upperBound)
        }

        return RouteDisplayFormatter.distanceMiles(sliderBounds.upperBound)
    }

    private var summary: String {
        guard hasReferenceRoutes else {
            return "No matching routes"
        }

        switch (model.selectedDistanceMinimumMiles, model.selectedDistanceMaximumMiles) {
        case (nil, nil):
            return "Any distance"
        case let (minimumMiles?, maximumMiles?):
            return "\(RouteDisplayFormatter.distanceMiles(minimumMiles)) - \(RouteDisplayFormatter.distanceMiles(maximumMiles))"
        case let (minimumMiles?, nil):
            return "\(RouteDisplayFormatter.distanceMiles(minimumMiles))+"
        case let (nil, maximumMiles?):
            return "Up to \(RouteDisplayFormatter.distanceMiles(maximumMiles))"
        }
    }

    private var minimumBinding: Binding<Double> {
        Binding(
            get: { currentMinimumDisplayDistance },
            set: { newValue in
                let clampedValue = min(newValue, currentMaximumDisplayDistance)
                let clampedMiles = RouteDisplayFormatter.miles(fromDistanceDisplayValue: clampedValue)
                model.selectedDistanceMinimumMiles = normalizedMinimum(clampedMiles)
                model.selectedDistance = .all
            }
        )
    }

    private var maximumBinding: Binding<Double> {
        Binding(
            get: { currentMaximumDisplayDistance },
            set: { newValue in
                let clampedValue = max(newValue, currentMinimumDisplayDistance)
                let clampedMiles = RouteDisplayFormatter.miles(fromDistanceDisplayValue: clampedValue)
                model.selectedDistanceMaximumMiles = normalizedMaximum(clampedMiles)
                model.selectedDistance = .all
            }
        )
    }

    private func normalizedMinimum(_ value: Double) -> Double? {
        value <= sliderBounds.lowerBound + 0.001 ? nil : value
    }

    private func normalizedMaximum(_ value: Double) -> Double? {
        value >= sliderBounds.upperBound - 0.001 ? nil : value
    }

    private func beginEditing(_ field: RangeEndpointField) {
        if let editingField, editingField != field {
            commit(field: editingField)
        }

        switch field {
        case .minimum:
            minimumDraft = model.selectedDistanceMinimumMiles.map(RouteDisplayFormatter.distanceInputValue(forMiles:)) ?? ""
        case .maximum:
            maximumDraft = model.selectedDistanceMaximumMiles.map(RouteDisplayFormatter.distanceInputValue(forMiles:)) ?? ""
        }

        editingField = field
    }

    private func finishEditing(_ field: RangeEndpointField) {
        guard editingField == field else {
            return
        }

        commit(field: field)
        editingField = nil
    }

    private func clear(field: RangeEndpointField) {
        switch field {
        case .minimum:
            minimumDraft = ""
            model.selectedDistanceMinimumMiles = nil
        case .maximum:
            maximumDraft = ""
            model.selectedDistanceMaximumMiles = nil
        }

        model.selectedDistance = .all
        editingField = nil
    }

    private func commit(field: RangeEndpointField) {
        switch field {
        case .minimum:
            applyDistanceInput(minimumDraft, field: .minimum)
            minimumDraft = model.selectedDistanceMinimumMiles.map(RouteDisplayFormatter.distanceInputValue(forMiles:)) ?? ""
        case .maximum:
            applyDistanceInput(maximumDraft, field: .maximum)
            maximumDraft = model.selectedDistanceMaximumMiles.map(RouteDisplayFormatter.distanceInputValue(forMiles:)) ?? ""
        }
    }

    private func applyDistanceInput(_ input: String, field: RangeEndpointField) {
        let trimmedInput = input.trimmed
        guard !trimmedInput.isEmpty else {
            switch field {
            case .minimum:
                model.selectedDistanceMinimumMiles = nil
            case .maximum:
                model.selectedDistanceMaximumMiles = nil
            }

            model.selectedDistance = .all
            return
        }

        guard let displayValue = RouteDisplayFormatter.parseNumericInput(trimmedInput) else {
            return
        }

        switch field {
        case .minimum:
            let clampedValue = min(displayValue, currentMaximumDisplayDistance)
            let clampedMiles = RouteDisplayFormatter.miles(fromDistanceDisplayValue: clampedValue)
            model.selectedDistanceMinimumMiles = normalizedMinimum(clampedMiles)
        case .maximum:
            let clampedValue = max(displayValue, currentMinimumDisplayDistance)
            let clampedMiles = RouteDisplayFormatter.miles(fromDistanceDisplayValue: clampedValue)
            model.selectedDistanceMaximumMiles = normalizedMaximum(clampedMiles)
        }

        model.selectedDistance = .all
    }

    private func resetDistance() {
        model.selectedDistance = .all
        model.selectedDistanceMinimumMiles = nil
        model.selectedDistanceMaximumMiles = nil
        minimumDraft = ""
        maximumDraft = ""
        editingField = nil
    }
}

private struct EditableRangeEndpointPill: View {
    let title: String
    let placeholder: String
    let displayValue: String
    let unitLabel: String
    @Binding var draft: String
    let isActive: Bool
    let isEditing: Bool
    let keyboardType: UIKeyboardType
    let onTap: () -> Void
    let onFinishEditing: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            if isEditing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField(placeholder, text: $draft)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isTextFieldFocused)

                    Text(unitLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                Text(displayValue)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .routeControlSurface(isActive: isActive, cornerRadius: 16)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else {
                return
            }

            onTap()
        }
        .onChange(of: isEditing) { _, newValue in
            guard newValue else {
                return
            }

            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
        .onChange(of: isTextFieldFocused) { _, newValue in
            guard !newValue, isEditing else {
                return
            }

            onFinishEditing()
        }
    }
}

private struct DualHandleRangeSlider: View {
    @Environment(\.colorScheme) private var colorScheme

    private enum Thumb {
        case lower
        case upper
    }

    @Binding var lowerValue: Double
    @Binding var upperValue: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityValue: String

    private let trackHeight: CGFloat = 6
    private let thumbHitSize: CGFloat = 32
    private let thumbVisualSize: CGFloat = 22
    private var sliderCenterY: CGFloat { thumbHitSize / 2 }

    var body: some View {
        GeometryReader { geometry in
            let layout = sliderLayout(in: geometry.size.width)
            let activeTrackWidth = max(trackHeight, layout.upperCenterX - layout.lowerCenterX)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? 0.14 : 0.08))
                    .frame(width: layout.trackWidth, height: trackHeight)
                    .offset(x: thumbHitSize / 2, y: sliderCenterY - (trackHeight / 2))

                Capsule(style: .continuous)
                    .fill(Color(red: 0.95, green: 0.48, blue: 0.26).opacity(isEnabled ? 0.95 : 0.45))
                    .frame(width: activeTrackWidth, height: trackHeight)
                    .offset(x: layout.lowerCenterX, y: sliderCenterY - (trackHeight / 2))

                sliderThumb(for: .lower, layout: layout)

                sliderThumb(for: .upper, layout: layout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(tapGesture(layout: layout))
        }
        .frame(height: thumbHitSize)
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private func thumbView() -> some View {
        Circle()
            .fill(colorScheme == .dark ? Color.white : Color(.systemBackground))
            .frame(width: thumbVisualSize, height: thumbVisualSize)
            .overlay {
                Circle()
                    .strokeBorder(
                        Color(red: 0.95, green: 0.48, blue: 0.26).opacity(0.85),
                        lineWidth: 1.5
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.12), radius: 5, x: 0, y: 2)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.24 : 0.8), lineWidth: 0.6)
            }
    }

    @ViewBuilder
    private func sliderThumb(for thumb: Thumb, layout: SliderLayout) -> some View {
        let xPosition = thumb == .lower ? layout.lowerX : layout.upperX
        let baseThumb = thumbView()
            .frame(width: thumbHitSize, height: thumbHitSize)
            .contentShape(Rectangle())
            .position(x: xPosition + (thumbHitSize / 2), y: sliderCenterY)

        if isEnabled {
            baseThumb.gesture(dragGesture(for: thumb, layout: layout))
        } else {
            baseThumb
        }
    }

    private func dragGesture(for thumb: Thumb, layout: SliderLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                updateNearestThumb(thumb, with: value.location.x, layout: layout)
            }
    }

    private func tapGesture(layout: SliderLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard isEnabled else {
                    return
                }

                let distanceToLower = abs(value.location.x - (layout.lowerX + thumbHitSize / 2))
                let distanceToUpper = abs(value.location.x - (layout.upperX + thumbHitSize / 2))
                let targetThumb: Thumb = distanceToLower <= distanceToUpper ? .lower : .upper
                updateNearestThumb(targetThumb, with: value.location.x, layout: layout)
            }
    }

    private func updateNearestThumb(_ thumb: Thumb, with locationX: CGFloat, layout: SliderLayout) {
        let rawValue = value(for: locationX, layout: layout)

        switch thumb {
        case .lower:
            lowerValue = min(rawValue, upperValue)
        case .upper:
            upperValue = max(rawValue, lowerValue)
        }
    }

    private func sliderLayout(in width: CGFloat) -> SliderLayout {
        let trackWidth = max(width - thumbHitSize, 1)
        let lowerFraction = normalizedFraction(for: lowerValue)
        let upperFraction = normalizedFraction(for: upperValue)
        return SliderLayout(
            trackWidth: trackWidth,
            lowerX: lowerFraction * trackWidth,
            upperX: upperFraction * trackWidth,
            lowerCenterX: (lowerFraction * trackWidth) + (thumbHitSize / 2),
            upperCenterX: (upperFraction * trackWidth) + (thumbHitSize / 2)
        )
    }

    private func normalizedFraction(for value: Double) -> CGFloat {
        guard bounds.upperBound > bounds.lowerBound else {
            return 0
        }

        let progress = (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        return CGFloat(progress.clamped(to: 0 ... 1))
    }

    private func value(for locationX: CGFloat, layout: SliderLayout) -> Double {
        let adjustedX = (locationX - (thumbHitSize / 2)).clamped(to: 0 ... layout.trackWidth)
        let fraction = adjustedX / layout.trackWidth
        let rawValue = bounds.lowerBound + Double(fraction) * (bounds.upperBound - bounds.lowerBound)
        let steppedValue = (rawValue / step).rounded() * step
        return steppedValue.clamped(to: bounds)
    }

    private struct SliderLayout {
        let trackWidth: CGFloat
        let lowerX: CGFloat
        let upperX: CGFloat
        let lowerCenterX: CGFloat
        let upperCenterX: CGFloat
    }
}

private struct ClimbRangePanel: View {
    @Bindable var model: RouteLibraryModel
    let sliderBounds: ClosedRange<Double>
    let filteredBounds: ClosedRange<Double>?
    @State private var editingField: RangeEndpointField?
    @State private var minimumDraft = ""
    @State private var maximumDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("ELEVATION GAIN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                Spacer(minLength: 0)

                if model.hasCustomClimbRange || model.selectedClimb != .all {
                    Button("Reset", action: resetClimb)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                EditableRangeEndpointPill(
                    title: "Min",
                    placeholder: "No minimum",
                    displayValue: minimumLabel,
                    unitLabel: RouteDisplayFormatter.measurementSystem.climbUnitLabel,
                    draft: $minimumDraft,
                    isActive: model.selectedClimbMinimumFeet != nil || editingField == .minimum,
                    isEditing: editingField == .minimum,
                    keyboardType: .numberPad,
                    onTap: { beginEditing(.minimum) },
                    onFinishEditing: { finishEditing(.minimum) }
                )
                EditableRangeEndpointPill(
                    title: "Max",
                    placeholder: "No maximum",
                    displayValue: maximumLabel,
                    unitLabel: RouteDisplayFormatter.measurementSystem.climbUnitLabel,
                    draft: $maximumDraft,
                    isActive: model.selectedClimbMaximumFeet != nil || editingField == .maximum,
                    isEditing: editingField == .maximum,
                    keyboardType: .numberPad,
                    onTap: { beginEditing(.maximum) },
                    onFinishEditing: { finishEditing(.maximum) }
                )
            }

            DualHandleRangeSlider(
                lowerValue: minimumBinding,
                upperValue: maximumBinding,
                bounds: displaySliderBounds,
                step: RouteDisplayFormatter.climbSliderStep,
                isEnabled: hasReferenceRoutes,
                accessibilityLabel: "Elevation gain range",
                accessibilityValue: summary
            )
        }
        .toolbar {
            if let editingField {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Clear") {
                        clear(field: editingField)
                    }

                    Spacer()

                    Button("Done") {
                        finishEditing(editingField)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var currentMinimumFeet: Double {
        min(
            max(model.selectedClimbMinimumFeet ?? sliderBounds.lowerBound, sliderBounds.lowerBound),
            currentMaximumFeet
        )
    }

    private var currentMaximumFeet: Double {
        max(
            min(model.selectedClimbMaximumFeet ?? sliderBounds.upperBound, sliderBounds.upperBound),
            sliderBounds.lowerBound
        )
    }

    private var currentMinimumDisplayClimb: Double {
        RouteDisplayFormatter.climbDisplayValue(forFeet: currentMinimumFeet)
    }

    private var currentMaximumDisplayClimb: Double {
        RouteDisplayFormatter.climbDisplayValue(forFeet: currentMaximumFeet)
    }

    private var displaySliderBounds: ClosedRange<Double> {
        RouteDisplayFormatter.climbDisplayValue(forFeet: sliderBounds.lowerBound) ... RouteDisplayFormatter.climbDisplayValue(forFeet: sliderBounds.upperBound)
    }

    private var hasReferenceRoutes: Bool {
        filteredBounds != nil
    }

    private var minimumLabel: String {
        if let selectedMinimum = model.selectedClimbMinimumFeet {
            return RouteDisplayFormatter.climbFeet(selectedMinimum)
        }

        if let filteredBounds {
            return RouteDisplayFormatter.climbFeet(filteredBounds.lowerBound)
        }

        return RouteDisplayFormatter.climbFeet(sliderBounds.lowerBound)
    }

    private var maximumLabel: String {
        if let selectedMaximum = model.selectedClimbMaximumFeet {
            return RouteDisplayFormatter.climbFeet(selectedMaximum)
        }

        if let filteredBounds {
            return RouteDisplayFormatter.climbFeet(filteredBounds.upperBound)
        }

        return RouteDisplayFormatter.climbFeet(sliderBounds.upperBound)
    }

    private var summary: String {
        guard hasReferenceRoutes else {
            return "No matching routes"
        }

        switch (model.selectedClimbMinimumFeet, model.selectedClimbMaximumFeet) {
        case (nil, nil):
            return "Any climb"
        case let (minimumFeet?, maximumFeet?):
            return "\(RouteDisplayFormatter.climbFeet(minimumFeet)) - \(RouteDisplayFormatter.climbFeet(maximumFeet))"
        case let (minimumFeet?, nil):
            return "\(RouteDisplayFormatter.climbFeet(minimumFeet))+"
        case let (nil, maximumFeet?):
            return "Up to \(RouteDisplayFormatter.climbFeet(maximumFeet))"
        }
    }

    private var minimumBinding: Binding<Double> {
        Binding(
            get: { currentMinimumDisplayClimb },
            set: { newValue in
                let clampedValue = min(newValue, currentMaximumDisplayClimb)
                let clampedFeet = RouteDisplayFormatter.feet(fromClimbDisplayValue: clampedValue)
                model.selectedClimbMinimumFeet = normalizedMinimum(clampedFeet)
                model.selectedClimb = .all
            }
        )
    }

    private var maximumBinding: Binding<Double> {
        Binding(
            get: { currentMaximumDisplayClimb },
            set: { newValue in
                let clampedValue = max(newValue, currentMinimumDisplayClimb)
                let clampedFeet = RouteDisplayFormatter.feet(fromClimbDisplayValue: clampedValue)
                model.selectedClimbMaximumFeet = normalizedMaximum(clampedFeet)
                model.selectedClimb = .all
            }
        )
    }

    private func normalizedMinimum(_ value: Double) -> Double? {
        value <= sliderBounds.lowerBound + 0.5 ? nil : value
    }

    private func normalizedMaximum(_ value: Double) -> Double? {
        value >= sliderBounds.upperBound - 0.5 ? nil : value
    }

    private func beginEditing(_ field: RangeEndpointField) {
        if let editingField, editingField != field {
            commit(field: editingField)
        }

        switch field {
        case .minimum:
            minimumDraft = model.selectedClimbMinimumFeet.map(RouteDisplayFormatter.climbInputValue(forFeet:)) ?? ""
        case .maximum:
            maximumDraft = model.selectedClimbMaximumFeet.map(RouteDisplayFormatter.climbInputValue(forFeet:)) ?? ""
        }

        editingField = field
    }

    private func finishEditing(_ field: RangeEndpointField) {
        guard editingField == field else {
            return
        }

        commit(field: field)
        editingField = nil
    }

    private func clear(field: RangeEndpointField) {
        switch field {
        case .minimum:
            minimumDraft = ""
            model.selectedClimbMinimumFeet = nil
        case .maximum:
            maximumDraft = ""
            model.selectedClimbMaximumFeet = nil
        }

        model.selectedClimb = .all
        editingField = nil
    }

    private func commit(field: RangeEndpointField) {
        switch field {
        case .minimum:
            applyClimbInput(minimumDraft, field: .minimum)
            minimumDraft = model.selectedClimbMinimumFeet.map(RouteDisplayFormatter.climbInputValue(forFeet:)) ?? ""
        case .maximum:
            applyClimbInput(maximumDraft, field: .maximum)
            maximumDraft = model.selectedClimbMaximumFeet.map(RouteDisplayFormatter.climbInputValue(forFeet:)) ?? ""
        }
    }

    private func applyClimbInput(_ input: String, field: RangeEndpointField) {
        let trimmedInput = input.trimmed
        guard !trimmedInput.isEmpty else {
            switch field {
            case .minimum:
                model.selectedClimbMinimumFeet = nil
            case .maximum:
                model.selectedClimbMaximumFeet = nil
            }

            model.selectedClimb = .all
            return
        }

        guard let displayValue = RouteDisplayFormatter.parseNumericInput(trimmedInput) else {
            return
        }

        switch field {
        case .minimum:
            let clampedValue = min(displayValue, currentMaximumDisplayClimb)
            let clampedFeet = RouteDisplayFormatter.feet(fromClimbDisplayValue: clampedValue)
            model.selectedClimbMinimumFeet = normalizedMinimum(clampedFeet)
        case .maximum:
            let clampedValue = max(displayValue, currentMinimumDisplayClimb)
            let clampedFeet = RouteDisplayFormatter.feet(fromClimbDisplayValue: clampedValue)
            model.selectedClimbMaximumFeet = normalizedMaximum(clampedFeet)
        }

        model.selectedClimb = .all
    }

    private func resetClimb() {
        model.selectedClimb = .all
        model.selectedClimbMinimumFeet = nil
        model.selectedClimbMaximumFeet = nil
        minimumDraft = ""
        maximumDraft = ""
        editingField = nil
    }
}

private struct SortPriorityPanel: View {
    @Bindable var model: RouteLibraryModel
    let hasSelectedStartLocation: Bool

    private var isAppStorePreview: Bool {
        AppStoreScreenshotSupport.requestedShot == .sortOrder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isAppStorePreview ? 6 : 10) {
            VStack(alignment: .leading, spacing: isAppStorePreview ? 6 : 8) {
                ForEach(Array(model.sortCriteria.enumerated()), id: \.element.id) { index, criterion in
                    SortCriterionRow(
                        index: index,
                        criterion: criterion,
                        availableOptions: availableSortOptions(for: criterion),
                        canMoveUp: index > 0,
                        canMoveDown: index < model.sortCriteria.count - 1,
                        canRemove: model.sortCriteria.count > 1,
                        hasSelectedStartLocation: hasSelectedStartLocation,
                        isCondensed: isAppStorePreview,
                        onSelectOption: { model.updateSortCriterion(criterion.id, option: $0) },
                        onToggleDirection: {
                            let nextDirection: RouteSortDirection = criterion.direction == .descending ? .ascending : .descending
                            model.updateSortCriterion(criterion.id, direction: nextDirection)
                        },
                        onMoveUp: { model.moveSortCriterion(criterion.id, by: -1) },
                        onMoveDown: { model.moveSortCriterion(criterion.id, by: 1) },
                        onRemove: { model.removeSortCriterion(criterion.id) }
                    )
                }
            }

            if !availableAdditionalSorts.isEmpty {
                Menu {
                    ForEach(availableAdditionalSorts) { option in
                        Button {
                            model.addSortCriterion(option)
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                        }
                    }
                } label: {
                    Label("Add Sort Criterion", systemImage: "plus")
                        .font(isAppStorePreview ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, isAppStorePreview ? 10 : 12)
                        .padding(.vertical, isAppStorePreview ? 8 : 10)
                        .routeControlSurface(isActive: false, cornerRadius: isAppStorePreview ? 18 : 20)
                }
            }

            if model.usesStartProximitySort && !hasSelectedStartLocation {
                Text("Pick a start reference to make Closest Start meaningful.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func availableSortOptions(for criterion: RouteSortCriterion) -> [RouteSortOption] {
        RouteSortOption.allCases.filter { option in
            option == criterion.option || !model.sortCriteria.contains(where: { $0.option == option })
        }
    }

    private var availableAdditionalSorts: [RouteSortOption] {
        RouteSortOption.allCases.filter { option in
            !model.sortCriteria.contains(where: { $0.option == option })
        }
    }
}

private struct SortCriterionRow: View {
    let index: Int
    let criterion: RouteSortCriterion
    let availableOptions: [RouteSortOption]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let hasSelectedStartLocation: Bool
    let isCondensed: Bool
    let onSelectOption: (RouteSortOption) -> Void
    let onToggleDirection: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isCondensed ? 4 : 6) {
            HStack(spacing: isCondensed ? 6 : 8) {
                Text("#\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Menu {
                    ForEach(availableOptions) { option in
                        Button {
                            onSelectOption(option)
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: criterion.option.symbolName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(criterion.option.title)
                            .font(isCondensed ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, isCondensed ? 10 : 12)
                    .padding(.vertical, isCondensed ? 8 : 10)
                    .routeControlSurface(isActive: false, cornerRadius: 18)
                }
                .buttonStyle(.plain)

                Button(action: onToggleDirection) {
                    HStack(spacing: 6) {
                        Image(systemName: criterion.direction.symbolName)
                            .font(.caption.weight(.bold))
                        Text(criterion.option.directionTitle(for: criterion.direction))
                            .font(isCondensed ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, isCondensed ? 8 : 10)
                    .padding(.vertical, isCondensed ? 8 : 10)
                    .routeControlSurface(isActive: false, cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: isCondensed ? 8 : 10) {
                Spacer(minLength: 32)

                SortRowAccessoryButton(
                    symbolName: "arrow.up",
                    isEnabled: canMoveUp,
                    action: onMoveUp,
                    isCondensed: isCondensed
                )

                SortRowAccessoryButton(
                    symbolName: "arrow.down",
                    isEnabled: canMoveDown,
                    action: onMoveDown,
                    isCondensed: isCondensed
                )

                if canRemove {
                    SortRowAccessoryButton(
                        symbolName: "minus.circle",
                        isEnabled: true,
                        action: onRemove,
                        isCondensed: isCondensed
                    )
                }

                if criterion.option == .startProximity {
                    Text(hasSelectedStartLocation ? "Using start reference" : "Needs start reference")
                        .font(isCondensed ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct SortRowAccessoryButton: View {
    let symbolName: String
    let isEnabled: Bool
    let action: () -> Void
    let isCondensed: Bool

    var body: some View {
        Button(action: action) {
            AppIconGlyph(name: symbolName, size: isCondensed ? 10 : 12, weight: .bold)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: isCondensed ? 24 : 28, height: isCondensed ? 24 : 28)
                .routeControlSurface(isActive: false, cornerRadius: isCondensed ? 12 : 14)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct FilterNavigationRow<Destination: View>: View {
    let title: String
    let summary: String
    let symbolName: String
    let isActive: Bool
    @ViewBuilder let destination: () -> Destination

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 2 : 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .routeControlSurface(isActive: isActive, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterActionRow: View {
    let title: String
    let summary: String
    let symbolName: String
    let isActive: Bool
    let action: () -> Void

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 2 : 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .routeControlSurface(isActive: isActive, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterToggleRow: View {
    let title: String
    let summary: String
    let symbolName: String
    @Binding var isOn: Bool

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 2 : 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .routeControlSurface(isActive: isOn, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterOptionSelectionScreen<Option: Identifiable & Hashable>: View {
    let title: String
    let descriptionText: String
    let options: [Option]
    let isSelected: (Option) -> Bool
    let action: (Option) -> Void
    let titleForOption: (Option) -> String
    let symbolNameForOption: (Option) -> String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !descriptionText.isEmpty {
                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(options) { option in
                        FilterSelectionRow(
                            title: titleForOption(option),
                            symbolName: symbolNameForOption(option),
                            isSelected: isSelected(option)
                        ) {
                            action(option)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TagSelectionScreen: View {
    let title: String
    let descriptionText: String
    let tags: [String]
    let selectedTags: Set<String>
    let onToggle: (String) -> Void

    @State private var query = ""

    private var filteredTags: [String] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return tags
        }

        return tags.filter { $0.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(descriptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SearchField(text: $query, placeholder: "Search tags")

                if filteredTags.isEmpty {
                    ContentUnavailableView(
                        "No Matching Tags",
                        systemImage: "number",
                        description: Text(query.isEmpty ? "No tags are available yet." : "Try a different search.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredTags, id: \.self) { tag in
                            FilterSelectionRow(
                                title: tag,
                                symbolName: "number",
                                isSelected: selectedTags.contains(tag)
                            ) {
                                onToggle(tag)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StartLocationSearchResult: Identifiable, Hashable {
    let selectionValue: String
    let subtitle: String?

    var id: String { selectionValue.routeLocationToken }

    init?(_ item: MKMapItem) {
        let primaryLine = StartLocationSearchResult.primaryLine(for: item)
        guard let selectionValue = primaryLine.nilIfEmpty else {
            return nil
        }

        self.selectionValue = selectionValue
        subtitle = StartLocationSearchResult.subtitle(for: item, excluding: selectionValue)
    }

    private static func primaryLine(for item: MKMapItem) -> String {
        let placemark = item.placemark

        return item.name?.trimmed.nilIfEmpty ??
            placemark.locality?.trimmed.nilIfEmpty ??
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty ??
            placemark.administrativeArea?.trimmed.nilIfEmpty ??
            placemark.country?.trimmed.nilIfEmpty ??
            placemark.title?.trimmed.nilIfEmpty ??
            ""
    }

    private static func subtitle(for item: MKMapItem, excluding primaryLine: String) -> String? {
        let placemark = item.placemark
        let parts = [
            placemark.locality?.trimmed.nilIfEmpty,
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty,
            placemark.administrativeArea?.trimmed.nilIfEmpty,
            placemark.country?.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty && $0.routeLocationToken != primaryLine.routeLocationToken }

        guard !parts.isEmpty else {
            return nil
        }

        var seen = Set<String>()
        let deduplicated = parts.filter { value in
            seen.insert(value.routeLocationToken).inserted
        }

        return deduplicated.joined(separator: ", ").nilIfEmpty
    }
}

private struct StartLocationFilterBox: View {
    let selectedValues: [String]
    let activeRadiusSummary: String?
    let activeRadiusReferenceName: String?
    @Binding var draft: String
    let searchResults: [StartLocationSearchResult]
    let isSearching: Bool
    let onSelectSearchResult: (StartLocationSearchResult) -> Void
    let onRemoveValue: (String) -> Void
    let onChooseOnMap: () -> Void
    let onClearRadius: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)

                TextField(textFieldPlaceholder, text: $draft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !draft.trimmed.isEmpty {
                    Button {
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if !searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a Location")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(searchResults) { result in
                            Button {
                                onSelectSearchResult(result)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.79, green: 0.32, blue: 0.15))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.selectionValue)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)

                                        if let subtitle = result.subtitle {
                                            Text(subtitle)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if draft.trimmed.count >= 2, !isSearching {
                Text("No matching places found. Try a broader location name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !selectedValues.isEmpty || activeRadiusSummary != nil {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(selectedValues, id: \.self) { value in
                        StartLocationValueChip(value: value) {
                            onRemoveValue(value)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let activeRadiusSummary {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Map Radius")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text(radiusSummaryText(activeRadiusSummary))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Button("Clear", action: onClearRadius)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.79, green: 0.32, blue: 0.15))
                            .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Button(action: onChooseOnMap) {
                    HStack(spacing: 10) {
                        Image(systemName: "map")
                            .font(.system(size: 15, weight: .semibold))
                        Text(activeRadiusSummary == nil ? "Choose on Map" : "Adjust on Map")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .routeControlSurface(isActive: activeRadiusSummary != nil, cornerRadius: 20)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var textFieldPlaceholder: String {
        "Search San Francisco, Marin, Yosemite, ..."
    }

    private func radiusSummaryText(_ summary: String) -> String {
        if let activeRadiusReferenceName = activeRadiusReferenceName?.trimmed.nilIfEmpty {
            return "\(summary) from \(activeRadiusReferenceName)"
        }

        return summary
    }
}

private struct StartLocationValueChip: View {
    let value: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.79, green: 0.32, blue: 0.15))

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .routeControlSurface(isActive: true, cornerRadius: 18)
    }
}

private struct InlineListFilterBox: View {
    let lists: [RouteList]
    let selectedTags: Set<String>
    let onToggle: (String) -> Void

    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)]

    private var listNames: [String] {
        lists.map(\.name)
    }

    private var filteredListNames: [String] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return listNames
        }

        return listNames.filter { $0.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if listNames.isEmpty {
                ContentUnavailableView(
                    "No Lists Yet",
                    systemImage: "list.bullet",
                    description: Text("Create lists from Manage Lists or route details, then filter them here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                SearchField(text: $query, placeholder: "Search lists")

                if filteredListNames.isEmpty {
                    ContentUnavailableView(
                        "No Matching Lists",
                        systemImage: "list.bullet",
                        description: Text("Try a different list search.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(filteredListNames, id: \.self) { listName in
                            ListFilterChip(
                                listName: listName,
                                isSelected: selectedTags.contains(listName)
                            ) {
                                onToggle(listName)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ListFilterChip: View {
    let listName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)

                Text(listName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .routeControlSurface(isActive: isSelected, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterSelectionRow: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 26 : 18, height: 26, alignment: .center)
                    .offset(y: usesActivityGlyph ? 1 : 0)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .routeControlSurface(isActive: isSelected, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct ControlMenuChip<MenuContent: View>: View {
    let title: String
    let value: String
    let symbolName: String
    let isActive: Bool
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AppIconGlyph(name: symbolName, size: 14, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .routeControlSurface(isActive: isActive, cornerRadius: 22)
        }
        .buttonStyle(.plain)
    }
}

private struct ActionControlChip: View {
    let title: String
    let value: String
    let symbolName: String
    let isActive: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIconGlyph(name: symbolName, size: 14, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !value.isEmpty {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .routeControlSurface(isActive: isActive, cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ToggleControlChip: View {
    let title: String
    let value: String
    let symbolName: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AppIconGlyph(name: symbolName, size: 14, weight: .semibold)
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .routeControlSurface(isActive: isOn, cornerRadius: 22)
        }
        .buttonStyle(.plain)
    }
}

private struct AppliedFilterToken: Identifiable {
    let id: String
    let title: String
    let value: String
    let symbolName: String
    let clear: () -> Void
}

private struct RouteMapBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue

    let model: RouteLibraryModel
    let allRoutes: [RouteRecord]
    let lists: [RouteList]

    private enum Constants {
        static let mapAreaReferenceName = "Map Area"
    }

    @State private var requestedRegion: MKCoordinateRegion?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var routesInCurrentMap: [RouteRecord]
    @State private var markerGroups: [RouteStartMarkerGroup]
    @State private var selectedRouteID: Int?
    @State private var selectedMarkerGroupID: String?
    @State private var lockedSelectedMarkerGroup: RouteStartMarkerGroup?
    @State private var centerOnUserRequestID = 1
    @State private var fitRequestID = 1
    @State private var isShowingFullScreenMap = false
    @State private var isShowingLocationSearch = false
    @State private var isShowingFiltersSheet = false
    @State private var hasRequestedInitialLocationCenter = false
    @State private var lastVisibleContentRefreshKey: String?
    @State private var didApplyScreenshotPresentation = false

    private let offlineAssetService = RouteOfflineAssetService()
    private let offlineDownloadCoordinator = RouteOfflineDownloadCoordinator()
    private let initialFallbackRegion: MKCoordinateRegion?

    init(
        model: RouteLibraryModel,
        allRoutes: [RouteRecord],
        lists: [RouteList]
    ) {
        self.model = model
        self.allRoutes = allRoutes
        self.lists = lists

        let service = RouteOfflineAssetService()
        let initialRoutes = model.filteredRoutes(from: allRoutes)
        let initialRegion = service.coordinateRegion(for: initialRoutes)
        initialFallbackRegion = initialRegion
        _requestedRegion = State(initialValue: nil)
        _visibleRegion = State(initialValue: nil)

        let initialVisibleRoutes = initialRoutes.filter { $0.startCoordinate != nil }
        _routesInCurrentMap = State(initialValue: initialVisibleRoutes)
        _markerGroups = State(initialValue: RouteStartMarkerGroup.groups(from: initialVisibleRoutes, region: initialRegion))
        _selectedRouteID = State(initialValue: model.selectedRoute?.stravaRouteID)
        _selectedMarkerGroupID = State(initialValue: nil)
    }

    private var filteredRoutes: [RouteRecord] {
        model.filteredRoutes(from: allRoutes)
    }

    private var routesWithStartCoordinates: [RouteRecord] {
        filteredRoutes.filter { $0.startCoordinate != nil }
    }

    private var selectedRoute: RouteRecord? {
        guard let selectedRouteID else {
            return nil
        }

        return filteredRoutes.first(where: { $0.stravaRouteID == selectedRouteID })
    }

    private var selectedMarkerGroup: RouteStartMarkerGroup? {
        if let lockedSelectedMarkerGroup {
            return lockedSelectedMarkerGroup
        }

        if let selectedMarkerGroupID,
           let matchedGroup = markerGroups.first(where: { $0.id == selectedMarkerGroupID }) {
            return matchedGroup
        }

        guard let selectedRouteID else {
            return nil
        }

        return markerGroups.first { group in
            group.routes.contains(where: { $0.stravaRouteID == selectedRouteID })
        }
    }

    private var displayedMarkerGroups: [RouteStartMarkerGroup] {
        if let selectedMarkerGroup {
            return [selectedMarkerGroup]
        }

        return markerGroups
    }

    private var supplementalRoutesInCurrentMap: [RouteRecord] {
        guard let selectedMarkerGroup else {
            return routesInCurrentMap
        }

        let selectedRouteIDs = Set(selectedMarkerGroup.routes.map(\.stravaRouteID))
        return routesInCurrentMap.filter { !selectedRouteIDs.contains($0.stravaRouteID) }
    }

    private var filteredRoutesSignature: Int {
        var hasher = Hasher()
        for route in filteredRoutes {
            hasher.combine(route.stravaRouteID)
            hasher.combine(route.primaryTimestamp.timeIntervalSince1970)
        }
        return hasher.finalize()
    }

    private var markerZoomStyle: RouteMapMarkerZoomStyle {
        RouteMapMarkerZoomStyle(region: visibleRegion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                RouteMapBrowseCanvas(
                    requestedRegion: $requestedRegion,
                    visibleRegion: $visibleRegion,
                    fallbackRegion: requestedRegion ?? initialFallbackRegion ?? offlineAssetService.coordinateRegion(for: filteredRoutes),
                    centerOnUserRequestID: $centerOnUserRequestID,
                    fitRequestID: $fitRequestID,
                    markerGroups: displayedMarkerGroups,
                    selectedRoute: selectedRoute,
                    selectedRouteID: selectedRouteID,
                    markerZoomStyle: markerZoomStyle,
                    appRouteMapStyle: appRouteMapStyle,
                    appRouteMapPerspective: appRouteMapPerspective,
                    onCameraRegionChanged: refreshVisibleMapContent,
                    onSelectMarkerGroup: selectMarkerGroup,
                    onTapMapBackground: deselectMapBrowseSelection,
                    controlsTopInset: 14
                ) { centerOnUserLocation in
                    VStack(spacing: 10) {
                        RouteMapSettingsButton()

                        MapOverlayIconButton(
                            systemImage: "magnifyingglass",
                            accessibilityLabel: "Search for a place"
                        ) {
                            isShowingLocationSearch = true
                        }

                        MapOverlayIconButton(
                            systemImage: "arrow.up.left.and.arrow.down.right",
                            accessibilityLabel: "Open map full screen"
                        ) {
                            isShowingFullScreenMap = true
                        }

                        MapOverlayIconButton(
                            systemImage: "location.fill",
                            accessibilityLabel: "Center on your location"
                        ) {
                            centerOnUserLocation()
                        }
                    }
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                CompactMapToggleChip(
                    title: "Map Filter",
                    symbolName: "scope",
                    isOn: visibleAreaFilterBinding
                )

                if let visibleAreaStatusText {
                    Text(visibleAreaStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            mapBrowseRouteList
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .id("map-browse-\(appMeasurementSystemRawValue)")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("map-browse-screen")
        .fullScreenCover(isPresented: $isShowingFullScreenMap) {
            RouteMapBrowseFullScreenView(
                filteredRoutes: filteredRoutes,
                requestedRegion: $requestedRegion,
                visibleRegion: $visibleRegion,
                fallbackRegion: requestedRegion ?? initialFallbackRegion ?? offlineAssetService.coordinateRegion(for: filteredRoutes),
                selectedRouteID: $selectedRouteID,
                selectedMarkerGroupID: $selectedMarkerGroupID,
                centerOnUserRequestID: $centerOnUserRequestID,
                fitRequestID: $fitRequestID,
                markerGroups: markerGroups,
                appRouteMapStyle: appRouteMapStyle,
                appRouteMapPerspective: appRouteMapPerspective,
                markerZoomStyle: markerZoomStyle,
                onCameraRegionChanged: refreshVisibleMapContent,
                onSelectMarkerGroup: selectMarkerGroup,
                onTapMapBackground: deselectMapBrowseSelection,
                onSelectRoute: { route in
                    selectRoute(route, recenter: false)
                }
            )
        }
        .sheet(isPresented: $isShowingLocationSearch) {
            RouteMapCenterSearchSheet(searchRegion: visibleRegion) { result in
                centerMap(on: result)
            }
        }
        .sheet(isPresented: $isShowingFiltersSheet) {
            NavigationStack {
                RouteFiltersSheet(
                    model: model,
                    allRoutes: allRoutes,
                    lists: lists
                )
            }
            .presentationDetents([.large])
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Filters") {
                    isShowingFiltersSheet = true
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("map-browse-filters-button")
            }
        }
        .onAppear {
            applyScreenshotPresentationIfNeeded()
            requestInitialLocationCenterIfNeeded()
            refreshVisibleMapContent()
        }
        .task(id: filteredRoutesSignature) {
            refreshVisibleMapContent()
        }
    }

    private var mapBrowseRouteList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                if let selectedMarkerGroup {
                    selectedGroupCarousel(selectedMarkerGroup)
                }

                if selectedMarkerGroup == nil || !supplementalRoutesInCurrentMap.isEmpty {
                    mapBrowseSupplementalRoutesSection
                        .padding(.top, selectedMarkerGroup == nil ? 0 : 2)
                }
            }
            .onChange(of: selectedRouteID) { _, newValue in
                guard let routeID = newValue,
                      supplementalRoutesInCurrentMap.prefix(40).contains(where: { $0.stravaRouteID == routeID }) else {
                    return
                }

                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollProxy.scrollTo(routeID, anchor: .top)
                }
            }
        }
    }

    private func applyScreenshotPresentationIfNeeded() {
        guard !didApplyScreenshotPresentation,
              AppStoreScreenshotSupport.requestedShot == .mapBrowseSanFrancisco else {
            return
        }

        didApplyScreenshotPresentation = true
        hasRequestedInitialLocationCenter = true
        selectedRouteID = nil
        selectedMarkerGroupID = nil
        requestedRegion = AppStoreScreenshotSupport.sanFranciscoBrowseRegion
        visibleRegion = AppStoreScreenshotSupport.sanFranciscoBrowseRegion

        DispatchQueue.main.async {
            isShowingFullScreenMap = true
        }
    }

    private var mapBrowseSupplementalRoutesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if supplementalRoutesInCurrentMap.isEmpty {
                ContentUnavailableView(
                    "No Routes In View",
                    systemImage: "map",
                    description: Text(filteredRoutes.isEmpty
                        ? "Adjust filters or sync more routes to browse them on the map."
                        : "Move the map or loosen filters to bring filtered routes into view.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(supplementalRoutesInCurrentMap.prefix(40)) { route in
                        mapBrowseRow(for: route)
                            .id(route.stravaRouteID)
                    }
                }

                if supplementalRoutesInCurrentMap.count > 40 {
                    Text("Showing the first 40 routes in the current map.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedGroupCarousel(_ group: RouteStartMarkerGroup) -> some View {
        RouteMapSelectedGroupCarousel(
            group: group,
            selectedRouteID: selectedRouteID,
            onSelect: { route in
                selectRoute(route, recenter: false)
            },
            onOpen: { route in
                model.selectedRoute = route
            }
        )
    }

    private func mapBrowseRow(for route: RouteRecord) -> some View {
        RouteMapBrowseRow(
            route: route,
            isSelected: selectedRouteID == route.stravaRouteID,
            onSelect: {
                selectRoute(route)
            },
            onOpen: {
                model.selectedRoute = route
            }
        )
    }

    private var isVisibleAreaFilterActive: Bool {
        model.selectedStartFilterMode == .radius &&
            model.selectedStartLocationName == Constants.mapAreaReferenceName
    }

    private var visibleAreaStatusText: String? {
        guard isVisibleAreaFilterActive else {
            return nil
        }

        if let selectedStartFilterValue = model.selectedStartFilterValue {
            return "Following map · \(selectedStartFilterValue)"
        }

        return "Following map"
    }

    private var visibleAreaFilterBinding: Binding<Bool> {
        Binding(
            get: { isVisibleAreaFilterActive },
            set: { isEnabled in
                if isEnabled {
                    applyVisibleAreaFilter()
                } else {
                    clearVisibleAreaFilter()
                }
            }
        )
    }

    private func fitToResults() {
        let targetRegion: MKCoordinateRegion?

        if let selectedRoute {
            targetRegion = offlineAssetService.coordinateRegion(for: selectedRoute)
        } else if let selectedMarkerGroup {
            targetRegion = offlineAssetService.coordinateRegion(for: selectedMarkerGroup.routes)
        } else {
            targetRegion = offlineAssetService.coordinateRegion(for: filteredRoutes)
        }

        guard let region = targetRegion else {
            return
        }

        requestedRegion = region
        visibleRegion = region
        fitRequestID += 1
        refreshVisibleMapContent(for: region)
    }

    private func requestInitialLocationCenterIfNeeded() {
        guard !hasRequestedInitialLocationCenter else {
            return
        }

        hasRequestedInitialLocationCenter = true
        clearInitialBrowseSelection()
        centerOnUserRequestID += 1
    }

    private func clearInitialBrowseSelection() {
        selectedRouteID = nil
        selectedMarkerGroupID = nil
        lockedSelectedMarkerGroup = nil
    }

    private func centerMap(on result: MapCenterSearchResult) {
        let region = MKCoordinateRegion(
            center: result.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.28, longitudeDelta: 0.28)
        )

        requestedRegion = region
        visibleRegion = region
        refreshVisibleMapContent(for: region)
    }

    private func selectMarkerGroup(_ group: RouteStartMarkerGroup) {
        let isAlreadySelected = selectedMarkerGroupID == group.id ||
            lockedSelectedMarkerGroup?.id == group.id ||
            (selectedMarkerGroupID == nil && group.contains(routeID: selectedRouteID))

        if isAlreadySelected {
            selectedMarkerGroupID = group.id
            lockedSelectedMarkerGroup = group
            return
        }

        selectedMarkerGroupID = group.id
        lockedSelectedMarkerGroup = group

        if !group.contains(routeID: selectedRouteID) {
            selectedRouteID = group.routes.first?.stravaRouteID
        }
    }

    private func selectRoute(_ route: RouteRecord, recenter: Bool = true) {
        lockedSelectedMarkerGroup = nil
        selectedMarkerGroupID = nil
        selectedRouteID = route.stravaRouteID

        if let group = markerGroups.first(where: { markerGroup in
            markerGroup.routes.contains(where: { $0.stravaRouteID == route.stravaRouteID })
        }) {
            selectedMarkerGroupID = group.id
            lockedSelectedMarkerGroup = group
        } else if let lockedSelectedMarkerGroup,
                  lockedSelectedMarkerGroup.contains(routeID: route.stravaRouteID) {
            selectedMarkerGroupID = lockedSelectedMarkerGroup.id
        }

        if recenter, let region = offlineAssetService.coordinateRegion(for: route) {
            requestedRegion = region
            visibleRegion = region
        }
    }

    private func syncSelectionWithVisibleGroups(using groups: [RouteStartMarkerGroup]? = nil) {
        guard lockedSelectedMarkerGroup == nil else {
            return
        }

        let groups = groups ?? markerGroups

        if let selectedRoute,
           let group = groups.first(where: { markerGroup in
               markerGroup.routes.contains(where: { $0.stravaRouteID == selectedRoute.stravaRouteID })
           }) {
            selectedMarkerGroupID = group.id
            return
        }

        selectedMarkerGroupID = nil
    }

    private func refreshVisibleMapContent(for region: MKCoordinateRegion? = nil) {
        let effectiveRegion = region ?? visibleRegion
        let refreshKey = visibleContentRefreshKey(for: effectiveRegion)

        if refreshKey == lastVisibleContentRefreshKey {
            return
        }

        lastVisibleContentRefreshKey = refreshKey
        let visibleRoutes: [RouteRecord]

        if let effectiveRegion {
            if isVisibleAreaFilterActive {
                applyVisibleAreaFilter(using: effectiveRegion, showsStatusMessage: false)
            }

            visibleRoutes = routesWithStartCoordinates.filter { route in
                guard let coordinate = route.startCoordinate else {
                    return false
                }

                return effectiveRegion.contains(coordinate)
            }
        } else {
            visibleRoutes = routesWithStartCoordinates
        }

        routesInCurrentMap = visibleRoutes

        if let lockedSelectedMarkerGroup {
            let availableRouteIDs = Set(routesWithStartCoordinates.map(\.stravaRouteID))
            let hasAnyVisibleLockedRoute = lockedSelectedMarkerGroup.routes.contains { route in
                availableRouteIDs.contains(route.stravaRouteID)
            }

            if hasAnyVisibleLockedRoute {
                return
            }

            self.lockedSelectedMarkerGroup = nil
            selectedMarkerGroupID = nil
            selectedRouteID = nil
        }

        let groupedRoutes = RouteStartMarkerGroup.groups(from: visibleRoutes, region: effectiveRegion)
        markerGroups = groupedRoutes
        syncSelectionWithVisibleGroups(using: groupedRoutes)
    }

    private func visibleContentRefreshKey(for region: MKCoordinateRegion?) -> String {
        let regionKey: String

        if let region {
            regionKey = [
                region.center.latitude,
                region.center.longitude,
                region.span.latitudeDelta,
                region.span.longitudeDelta
            ]
            .map { String(format: "%.4f", $0) }
            .joined(separator: "|")
        } else {
            regionKey = "none"
        }

        return "\(filteredRoutesSignature)|\(isVisibleAreaFilterActive)|\(regionKey)"
    }

    private func applyVisibleAreaFilter() {
        let region = visibleRegion ?? offlineAssetService.coordinateRegion(for: filteredRoutes)
        guard let region else {
            return
        }

        applyVisibleAreaFilter(using: region, showsStatusMessage: true)
    }

    private func applyVisibleAreaFilter(
        using region: MKCoordinateRegion,
        showsStatusMessage: Bool
    ) {
        guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else {
            return
        }

        let center = region.center
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let northEdge = CLLocation(
            latitude: center.latitude + (region.span.latitudeDelta / 2),
            longitude: center.longitude
        )
        let eastEdge = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude + (region.span.longitudeDelta / 2)
        )

        let radiusMiles = max(
            northEdge.distance(from: centerLocation),
            eastEdge.distance(from: centerLocation)
        ) / 1_609.34

        model.setSelectedStartLocation(
            name: Constants.mapAreaReferenceName,
            coordinate: center,
            details: RouteStartLocationDetails(
                referenceName: Constants.mapAreaReferenceName,
                regionName: "",
                parkName: "",
                countyName: "",
                cityName: "",
                stateName: "",
                countryName: ""
            )
        )
        model.selectedStartLocationRadiusMiles = max(radiusMiles, 1)
        model.setStartFilterMode(.radius)

        if showsStatusMessage {
            model.statusMessage = "Map filter now follows the visible map area."
        }
    }

    private func clearVisibleAreaFilter() {
        guard isVisibleAreaFilterActive else {
            return
        }

        model.clearSelectedStartLocation()
        model.statusMessage = "Removed the visible map area filter."
    }

    private func deselectMapBrowseSelection() {
        guard selectedMarkerGroupID != nil || selectedRouteID != nil else {
            return
        }

        lockedSelectedMarkerGroup = nil
        selectedMarkerGroupID = nil
        selectedRouteID = nil
        refreshVisibleMapContent()
    }

    private var appRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private var appRouteMapPerspective: AppRouteMapPerspective {
        AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? AppRouteMapPerspective.defaultValue
    }
}

private struct MapCenterSearchResult: Identifiable, Hashable {
    let title: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double

    var id: String {
        "\(title.routeLocationToken)-\(subtitle?.routeLocationToken ?? "")-\(latitude)-\(longitude)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init?(_ item: MKMapItem) {
        let title = MapCenterSearchResult.primaryLine(for: item)
        guard let title = title.nilIfEmpty else {
            return nil
        }

        self.title = title
        subtitle = MapCenterSearchResult.subtitle(for: item, excluding: title)
        latitude = item.placemark.coordinate.latitude
        longitude = item.placemark.coordinate.longitude
    }

    private static func primaryLine(for item: MKMapItem) -> String {
        let placemark = item.placemark

        return item.name?.trimmed.nilIfEmpty ??
            placemark.locality?.trimmed.nilIfEmpty ??
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty ??
            placemark.administrativeArea?.trimmed.nilIfEmpty ??
            placemark.country?.trimmed.nilIfEmpty ??
            placemark.title?.trimmed.nilIfEmpty ??
            ""
    }

    private static func subtitle(for item: MKMapItem, excluding primaryLine: String) -> String? {
        let placemark = item.placemark
        let parts = [
            placemark.locality?.trimmed.nilIfEmpty,
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty,
            placemark.administrativeArea?.trimmed.nilIfEmpty,
            placemark.country?.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty && $0.routeLocationToken != primaryLine.routeLocationToken }

        guard !parts.isEmpty else {
            return nil
        }

        var seen = Set<String>()
        let deduplicated = parts.filter { value in
            seen.insert(value.routeLocationToken).inserted
        }

        return deduplicated.joined(separator: ", ").nilIfEmpty
    }
}

private struct RouteMapCenterSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let searchRegion: MKCoordinateRegion?
    let onSelect: (MapCenterSearchResult) -> Void

    @State private var searchQuery = ""
    @State private var searchResults: [MapCenterSearchResult] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            Group {
                if searchQuery.trimmed.isEmpty {
                    ContentUnavailableView(
                        "Search for a place",
                        systemImage: "magnifyingglass",
                        description: Text("Find a city, park, state, or landmark and center the browse map there.")
                    )
                } else if isSearching && searchResults.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching places...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "map",
                        description: Text("Try a broader place name.")
                    )
                } else {
                    List(searchResults) { result in
                        Button {
                            onSelect(result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)

                                if let subtitle = result.subtitle {
                                    Text(subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Find Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places")
            .task(id: searchQuery) {
                await refreshSearchResults()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func refreshSearchResults() async {
        let trimmedQuery = searchQuery.trimmed
        guard trimmedQuery.count >= 2 else {
            await MainActor.run {
                isSearching = false
                searchResults = []
            }
            return
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            isSearching = true
        }

        defer {
            Task { @MainActor in
                isSearching = false
            }
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery

        if let searchRegion {
            request.region = searchRegion
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.compactMap(MapCenterSearchResult.init)
            let deduplicatedResults = deduplicated(results)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                searchResults = deduplicatedResults
            }
        } catch {
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                searchResults = []
            }
        }
    }

    private func deduplicated(_ results: [MapCenterSearchResult]) -> [MapCenterSearchResult] {
        var seen = Set<String>()
        var deduplicatedResults: [MapCenterSearchResult] = []

        for result in results {
            let token = "\(result.title.routeLocationToken)-\(result.subtitle?.routeLocationToken ?? "")"
            guard !token.isEmpty, seen.insert(token).inserted else {
                continue
            }

            deduplicatedResults.append(result)
        }

        return deduplicatedResults
    }
}

private enum RouteMapMarkerZoomStyle {
    case far
    case standard
    case close

    init(region: MKCoordinateRegion?) {
        let span = max(region?.span.latitudeDelta ?? 180, region?.span.longitudeDelta ?? 180)

        switch span {
        case 6...:
            self = .far
        case 1.25...:
            self = .standard
        default:
            self = .close
        }
    }

    var outerDiameter: CGFloat {
        switch self {
        case .far:
            return 16
        case .standard:
            return 20
        case .close:
            return 24
        }
    }

    var coreDiameter: CGFloat {
        switch self {
        case .far:
            return 5
        case .standard:
            return 7
        case .close:
            return 9
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .far:
            return 1.75
        case .standard:
            return 2.25
        case .close:
            return 2.75
        }
    }

    var badgeHorizontalPadding: CGFloat {
        switch self {
        case .far:
            return 4
        case .standard:
            return 5
        case .close:
            return 6
        }
    }

    var badgeVerticalPadding: CGFloat {
        switch self {
        case .far:
            return 2
        case .standard:
            return 3
        case .close:
            return 4
        }
    }

    var badgeOffset: CGSize {
        switch self {
        case .far:
            return CGSize(width: 8, height: -6)
        case .standard:
            return CGSize(width: 10, height: -8)
        case .close:
            return CGSize(width: 12, height: -10)
        }
    }

    var badgeFont: Font {
        switch self {
        case .far, .standard:
            return .caption2.weight(.bold)
        case .close:
            return .caption.weight(.bold)
        }
    }

    var cacheBucket: Int {
        switch self {
        case .far:
            return 0
        case .standard:
            return 1
        case .close:
            return 2
        }
    }
}

private struct MapOverlayIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct CompactMapToggleChip: View {
    let title: String
    let symbolName: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                AppIconGlyph(name: symbolName, size: 13, weight: .semibold)
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .routeControlSurface(isActive: isOn, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct RouteMapBrowseCanvas<Controls: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var requestedRegion: MKCoordinateRegion?
    @Binding var visibleRegion: MKCoordinateRegion?
    let fallbackRegion: MKCoordinateRegion?
    @Binding var centerOnUserRequestID: Int
    @Binding var fitRequestID: Int
    let markerGroups: [RouteStartMarkerGroup]
    let selectedRoute: RouteRecord?
    let selectedRouteID: Int?
    let markerZoomStyle: RouteMapMarkerZoomStyle
    let appRouteMapStyle: AppRouteMapStyle
    let appRouteMapPerspective: AppRouteMapPerspective
    let onCameraRegionChanged: (MKCoordinateRegion) -> Void
    let onSelectMarkerGroup: (RouteStartMarkerGroup) -> Void
    let onTapMapBackground: () -> Void
    let controlsTopInset: CGFloat
    @ViewBuilder let controls: (_ centerOnUserLocation: @escaping () -> Void) -> Controls

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RouteMapBrowseRepresentable(
                requestedRegion: $requestedRegion,
                visibleRegion: $visibleRegion,
                fallbackRegion: fallbackRegion,
                centerOnUserRequestID: centerOnUserRequestID,
                fitRequestID: fitRequestID,
                markerGroups: markerGroups,
                selectedRoute: selectedRoute,
                selectedRouteID: selectedRouteID,
                markerZoomStyle: markerZoomStyle,
                routeMapStyle: appRouteMapStyle,
                routeMapPerspective: appRouteMapPerspective,
                userInterfaceStyle: colorScheme == .dark ? .dark : .light,
                onCameraRegionChanged: onCameraRegionChanged,
                onSelectMarkerGroup: onSelectMarkerGroup,
                onTapMapBackground: onTapMapBackground
            )

            VStack(spacing: 10) {
                controls(centerOnUserLocation)
            }
            .padding(.top, controlsTopInset)
            .padding(.trailing, 14)
            .padding(.bottom, 14)
        }
    }

    private func centerOnUserLocation() {
        centerOnUserRequestID += 1
    }
}

private struct RouteMapBrowseRepresentable: UIViewRepresentable {
    @Binding var requestedRegion: MKCoordinateRegion?
    @Binding var visibleRegion: MKCoordinateRegion?
    let fallbackRegion: MKCoordinateRegion?

    let centerOnUserRequestID: Int
    let fitRequestID: Int
    let markerGroups: [RouteStartMarkerGroup]
    let selectedRoute: RouteRecord?
    let selectedRouteID: Int?
    let markerZoomStyle: RouteMapMarkerZoomStyle
    let routeMapStyle: AppRouteMapStyle
    let routeMapPerspective: AppRouteMapPerspective
    let userInterfaceStyle: UIUserInterfaceStyle
    let onCameraRegionChanged: (MKCoordinateRegion) -> Void
    let onSelectMarkerGroup: (RouteStartMarkerGroup) -> Void
    let onTapMapBackground: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCameraRegionChanged: onCameraRegionChanged,
            onSelectMarkerGroup: onSelectMarkerGroup,
            onTapMapBackground: onTapMapBackground
        )
    }

    func makeUIView(context: Context) -> MapView {
        RouteVaultMapboxConfiguration.configure()

        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                mapStyle: routeMapStyle.resolvedStyle(colorScheme: userInterfaceStyle),
                cameraOptions: CameraOptions(
                    center: requestedRegion?.center,
                    zoom: 8,
                    pitch: routeMapPerspective.isThreeDimensional ? routeMapPerspective.pitch : 0
                )
            )
        )
        context.coordinator.bind(mapView, visibleRegion: $visibleRegion)
        configure(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.bind(mapView, visibleRegion: $visibleRegion)
        configure(mapView)
        context.coordinator.update(
            mapView: mapView,
            requestedRegion: requestedRegion,
            fallbackRegion: fallbackRegion,
            centerOnUserRequestID: centerOnUserRequestID,
            fitRequestID: fitRequestID,
            markerGroups: markerGroups,
            selectedRoute: selectedRoute,
            selectedRouteID: selectedRouteID,
            markerZoomStyle: markerZoomStyle,
            routeMapStyle: routeMapStyle,
            routeMapPerspective: routeMapPerspective,
            userInterfaceStyle: userInterfaceStyle
        )
    }

    private func configure(_ mapView: MapView) {
        mapView.location.options.puckType = .puck2D()
        mapView.gestures.options.rotateEnabled = true
        mapView.gestures.options.pitchEnabled = routeMapPerspective.isThreeDimensional

        var ornamentOptions = mapView.ornaments.options
        ornamentOptions.compass.visibility = .hidden
        ornamentOptions.scaleBar.visibility = .hidden
        mapView.ornaments.options = ornamentOptions
    }

    final class Coordinator {
        private struct BrowseRouteRenderState {
            let selectedRoute: RouteRecord?
            let selectedRouteID: Int?
            let markerGroups: [RouteStartMarkerGroup]
            let markerZoomStyle: RouteMapMarkerZoomStyle
            let perspective: AppRouteMapPerspective
            let usesStandardDarkReadabilityTuning: Bool
        }

        private struct MarkerImageCacheKey: Hashable {
            let routeCount: Int
            let isSelected: Bool
            let zoomBucket: Int
        }

        private let onCameraRegionChanged: (MKCoordinateRegion) -> Void
        private let onSelectMarkerGroup: (RouteStartMarkerGroup) -> Void
        private let onTapMapBackground: () -> Void

        private weak var mapView: MapView?
        private var cancelables = Set<AnyCancelable>()
        private var visibleRegionBinding: Binding<MKCoordinateRegion?>?
        private var routeOutlineManager: PolylineAnnotationManager?
        private var routeLineManager: PolylineAnnotationManager?
        private var directionArrowManager: PointAnnotationManager?
        private var pointManager: PointAnnotationManager?
        private var lastRequestedRegionKey: String?
        private var lastCenterOnUserRequestID: Int = -1
        private var lastFitRequestID: Int = -1
        private var lastStyleKey: String?
        private var lastMarkerKey: Int?
        private var lastSelectedRouteSignature: Int?
        private var lastPerspectiveRawValue: String?
        private var lastPublishedCameraKey: String?
        private var hasAppliedInitialUserCenter = false
        private var currentBrowseRenderState: BrowseRouteRenderState?
        private var preservedCameraOnNextStyleLoad: CameraOptions?
        private var cameraChangePublishTask: Task<Void, Never>?
        private var markerImageCache: [MarkerImageCacheKey: UIImage] = [:]
        private var lastMarkerTapTimestamp: TimeInterval = 0
        private var tapInteractionCancelable: Cancelable?

        init(
            onCameraRegionChanged: @escaping (MKCoordinateRegion) -> Void,
            onSelectMarkerGroup: @escaping (RouteStartMarkerGroup) -> Void,
            onTapMapBackground: @escaping () -> Void
        ) {
            self.onCameraRegionChanged = onCameraRegionChanged
            self.onSelectMarkerGroup = onSelectMarkerGroup
            self.onTapMapBackground = onTapMapBackground
        }

        func bind(_ mapView: MapView, visibleRegion: Binding<MKCoordinateRegion?>) {
            guard self.mapView !== mapView else {
                visibleRegionBinding = visibleRegion
                return
            }

            cancelables.removeAll()
            tapInteractionCancelable?.cancel()
            tapInteractionCancelable = nil
            self.mapView = mapView
            self.visibleRegionBinding = visibleRegion

            mapView.mapboxMap.onStyleLoaded.observeNext { [weak self, weak mapView] _ in
                guard let self, let mapView else {
                    return
                }

                RouteMapStyleReadabilityTuning.apply(
                    to: mapView.mapboxMap,
                    usesStandardDarkStyle: self.currentBrowseRenderState?.usesStandardDarkReadabilityTuning ?? false
                )
                RouteMapTerrainTuning.apply(
                    to: mapView.mapboxMap,
                    perspective: self.currentBrowseRenderState?.perspective ?? .defaultValue
                )
                self.recreateManagers(on: mapView)
                self.reapplyCurrentState(on: mapView)
            }
            .store(in: &cancelables)

            mapView.location.onLocationChange.observeNext { [weak self, weak mapView] _ in
                guard let self, let mapView else {
                    return
                }

                guard !self.hasAppliedInitialUserCenter else {
                    return
                }

                self.hasAppliedInitialUserCenter = true
                let fallbackRegion = self.visibleRegionBinding?.wrappedValue
                let perspective = self.currentBrowseRenderState?.perspective ?? .twoDimensional
                self.centerOnUserLocation(on: mapView, fallback: fallbackRegion, perspective: perspective)
            }
            .store(in: &cancelables)

            mapView.mapboxMap.onCameraChanged.observe { [weak self, weak mapView] _ in
                guard let self, let mapView else {
                    return
                }

                let bounds = mapView.mapboxMap.coordinateBounds(for: mapView.bounds)
                let region = RouteMapboxGeometry.coordinateRegion(for: bounds)
                self.cameraChangePublishTask?.cancel()
                self.cameraChangePublishTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(90))
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    let regionKey = Self.cameraRegionKey(for: region)
                    guard regionKey != self.lastPublishedCameraKey else {
                        return
                    }

                    self.lastPublishedCameraKey = regionKey
                    self.renderRouteLine(self.currentBrowseRenderState?.selectedRoute)
                    self.visibleRegionBinding?.wrappedValue = region
                    self.onCameraRegionChanged(region)
                }
            }
            .store(in: &cancelables)

            tapInteractionCancelable = mapView.mapboxMap.addInteraction(
                TapInteraction { [weak self] _ in
                    guard let self else {
                        return false
                    }

                    let currentTimestamp = ProcessInfo.processInfo.systemUptime
                    guard currentTimestamp - self.lastMarkerTapTimestamp > 0.2 else {
                        return false
                    }

                    self.onTapMapBackground()
                    return true
                }
            )
        }

        func update(
            mapView: MapView,
            requestedRegion: MKCoordinateRegion?,
            fallbackRegion: MKCoordinateRegion?,
            centerOnUserRequestID: Int,
            fitRequestID: Int,
            markerGroups: [RouteStartMarkerGroup],
            selectedRoute: RouteRecord?,
            selectedRouteID: Int?,
            markerZoomStyle: RouteMapMarkerZoomStyle,
            routeMapStyle: AppRouteMapStyle,
            routeMapPerspective: AppRouteMapPerspective,
            userInterfaceStyle: UIUserInterfaceStyle
        ) {
            currentBrowseRenderState = BrowseRouteRenderState(
                selectedRoute: selectedRoute,
                selectedRouteID: selectedRouteID,
                markerGroups: markerGroups,
                markerZoomStyle: markerZoomStyle,
                perspective: routeMapPerspective,
                usesStandardDarkReadabilityTuning: routeMapStyle.usesStandardDarkReadabilityTuning(
                    colorScheme: userInterfaceStyle
                )
            )
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: routeMapPerspective
            )

            let styleKey = "\(routeMapStyle.rawValue)-\(userInterfaceStyle.rawValue)"
            if styleKey != lastStyleKey {
                lastStyleKey = styleKey
                preservedCameraOnNextStyleLoad = currentCameraOptions(from: mapView)
                mapView.mapboxMap.mapStyle = routeMapStyle.resolvedStyle(colorScheme: userInterfaceStyle)
                recreateManagers(on: mapView)
                lastSelectedRouteSignature = nil
            }

            ensureManagers(on: mapView)
            updateRouteLine(selectedRoute, on: mapView, perspective: routeMapPerspective)
            updateMarkerAnnotations(
                markerGroups,
                selectedRouteID: selectedRouteID,
                zoomStyle: markerZoomStyle
            )

            let regionKey = requestedRegion.map {
                [
                    $0.center.latitude,
                    $0.center.longitude,
                    $0.span.latitudeDelta,
                    $0.span.longitudeDelta
                ]
                .map { String(format: "%.6f", $0) }
                .joined(separator: "|")
            }

            let perspectiveDidChange = routeMapPerspective.rawValue != lastPerspectiveRawValue

            if regionKey != lastRequestedRegionKey {
                lastRequestedRegionKey = regionKey
                if let requestedRegion {
                    setRegion(requestedRegion, on: mapView, perspective: routeMapPerspective)
                }
            } else if fitRequestID != lastFitRequestID, let requestedRegion {
                setRegion(requestedRegion, on: mapView, perspective: routeMapPerspective)
            } else if perspectiveDidChange && selectedRoute == nil {
                applyPerspective(routeMapPerspective, on: mapView)
            }

            if centerOnUserRequestID != lastCenterOnUserRequestID {
                lastCenterOnUserRequestID = centerOnUserRequestID
                hasAppliedInitialUserCenter = centerOnUserLocation(
                    on: mapView,
                    fallback: requestedRegion ?? fallbackRegion,
                    perspective: routeMapPerspective
                )
            }

            lastPerspectiveRawValue = routeMapPerspective.rawValue
            lastFitRequestID = fitRequestID
        }

        private func recreateManagers(on mapView: MapView) {
            mapView.annotations.removeAnnotationManager(withId: "browse-route-line-outline")
            mapView.annotations.removeAnnotationManager(withId: "browse-route-line")
            mapView.annotations.removeAnnotationManager(withId: "browse-route-direction-arrows")
            mapView.annotations.removeAnnotationManager(withId: "browse-start-points")
            routeOutlineManager = mapView.annotations.makePolylineAnnotationManager(id: "browse-route-line-outline")
            routeLineManager = mapView.annotations.makePolylineAnnotationManager(id: "browse-route-line")
            directionArrowManager = mapView.annotations.makePointAnnotationManager(id: "browse-route-direction-arrows")
            pointManager = mapView.annotations.makePointAnnotationManager(id: "browse-start-points")
        }

        private func ensureManagers(on mapView: MapView) {
            if routeOutlineManager == nil ||
                routeLineManager == nil ||
                directionArrowManager == nil ||
                pointManager == nil {
                recreateManagers(on: mapView)
            }
        }

        private func reapplyCurrentState(on mapView: MapView) {
            guard let currentBrowseRenderState else {
                return
            }

            ensureManagers(on: mapView)
            renderRouteLine(currentBrowseRenderState.selectedRoute)
            renderMarkerAnnotations(
                currentBrowseRenderState.markerGroups,
                selectedRouteID: currentBrowseRenderState.selectedRouteID,
                zoomStyle: currentBrowseRenderState.markerZoomStyle
            )

            if let preservedCameraOnNextStyleLoad {
                mapView.camera.ease(to: preservedCameraOnNextStyleLoad, duration: 0)
                self.preservedCameraOnNextStyleLoad = nil
            }
        }

        private func updateRouteLine(
            _ selectedRoute: RouteRecord?,
            on mapView: MapView,
            perspective: AppRouteMapPerspective
        ) {
            guard let selectedRoute,
                  !selectedRoute.routeCoordinates.isEmpty else {
                routeOutlineManager?.annotations = []
                routeLineManager?.annotations = []
                directionArrowManager?.annotations = []
                lastSelectedRouteSignature = nil
                return
            }

            var hasher = Hasher()
            hasher.combine(selectedRoute.stravaRouteID)
            hasher.combine(selectedRoute.routeGeometryPolyline)
            hasher.combine(perspective.rawValue)
            let signature = hasher.finalize()
            guard signature != lastSelectedRouteSignature else {
                return
            }

            lastSelectedRouteSignature = signature
            renderRouteLine(selectedRoute)

            do {
                let camera = try mapView.mapboxMap.camera(
                    for: selectedRoute.routeCoordinates,
                    camera: CameraOptions(
                        bearing: 0,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    coordinatesPadding: UIEdgeInsets(top: 70, left: 60, bottom: 70, right: 60),
                    maxZoom: nil,
                    offset: nil
                )
                mapView.camera.ease(to: camera, duration: 0.3)
            } catch { }
        }

        private func renderRouteLine(_ selectedRoute: RouteRecord?) {
            guard let selectedRoute,
                  !selectedRoute.routeCoordinates.isEmpty else {
                routeOutlineManager?.annotations = []
                routeLineManager?.annotations = []
                directionArrowManager?.annotations = []
                return
            }

            var outlinePolyline = PolylineAnnotation(lineCoordinates: selectedRoute.routeCoordinates)
            outlinePolyline.lineColor = StyleColor(RouteMapLineStyle.outlineColor)
            outlinePolyline.lineWidth = RouteMapLineStyle.outlineWidth

            var routePolyline = PolylineAnnotation(lineCoordinates: selectedRoute.routeCoordinates)
            routePolyline.lineColor = StyleColor(RouteMapLineStyle.fillColor)
            routePolyline.lineWidth = RouteMapLineStyle.fillWidth

            routeOutlineManager?.lineDasharray = nil
            routeOutlineManager?.annotations = [outlinePolyline]

            routeLineManager?.lineDasharray = selectedRoute.surfaceKind == .paved ? nil : RouteMapLineStyle.unpavedDashPattern
            routeLineManager?.annotations = [routePolyline]
            directionArrowManager?.annotations = RouteDirectionArrowRenderer.annotations(
                for: selectedRoute.routeCoordinates,
                imageNamePrefix: "browse-route-direction-arrow",
                zoomLevel: mapView.map { CGFloat($0.mapboxMap.cameraState.zoom) },
                visibleBounds: mapView.map { $0.mapboxMap.coordinateBounds(for: $0.bounds) }
            )
        }

        private func updateMarkerAnnotations(
            _ markerGroups: [RouteStartMarkerGroup],
            selectedRouteID: Int?,
            zoomStyle: RouteMapMarkerZoomStyle
        ) {
            var hasher = Hasher()
            hasher.combine(markerGroups.count)
            hasher.combine(selectedRouteID)

            for group in markerGroups {
                hasher.combine(group.id)
                hasher.combine(group.routes.count)
                hasher.combine(group.contains(routeID: selectedRouteID))
                hasher.combine(Int((group.coordinate.latitude * 100_000).rounded()))
                hasher.combine(Int((group.coordinate.longitude * 100_000).rounded()))
            }

            let markerKey = hasher.finalize()

            guard markerKey != lastMarkerKey else {
                return
            }

            lastMarkerKey = markerKey
            renderMarkerAnnotations(
                markerGroups,
                selectedRouteID: selectedRouteID,
                zoomStyle: zoomStyle
            )
        }

        private func renderMarkerAnnotations(
            _ markerGroups: [RouteStartMarkerGroup],
            selectedRouteID: Int?,
            zoomStyle: RouteMapMarkerZoomStyle
        ) {
            let annotations = markerGroups.map { group -> PointAnnotation in
                var annotation = PointAnnotation(coordinate: group.coordinate)
                annotation.image = .init(
                    image: markerImage(
                        routeCount: group.routes.count,
                        isSelected: group.contains(routeID: selectedRouteID),
                        zoomStyle: zoomStyle
                    ),
                    name: "browse-marker-\(group.id)"
                )
                annotation.tapHandler = { [weak self] _ in
                    self?.lastMarkerTapTimestamp = ProcessInfo.processInfo.systemUptime
                    self?.onSelectMarkerGroup(group)
                    return true
                }
                return annotation
            }

            pointManager?.annotations = annotations
        }

        private func setRegion(
            _ region: MKCoordinateRegion,
            on mapView: MapView,
            perspective: AppRouteMapPerspective
        ) {
            let bounds = RouteMapboxGeometry.coordinateBounds(for: region)
            do {
                let camera = try mapView.mapboxMap.camera(
                    for: [bounds.southwest, bounds.northeast],
                    camera: CameraOptions(
                        bearing: 0,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    coordinatesPadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                    maxZoom: nil,
                    offset: nil
                )
                mapView.camera.ease(to: camera, duration: 0.3)
            } catch {
                mapView.camera.ease(
                    to: CameraOptions(
                        center: region.center,
                        zoom: 8,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    duration: 0.3
                )
            }
        }

        @discardableResult
        private func centerOnUserLocation(
            on mapView: MapView,
            fallback: MKCoordinateRegion?,
            perspective: AppRouteMapPerspective
        ) -> Bool {
            if let coordinate = mapView.location.latestLocation?.coordinate {
                mapView.camera.ease(
                    to: CameraOptions(
                        center: coordinate,
                        zoom: 11.5,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    duration: 0.35
                )
                return true
            } else if let fallback {
                setRegion(fallback, on: mapView, perspective: perspective)
            }

            return false
        }

        private func applyPerspective(
            _ perspective: AppRouteMapPerspective,
            on mapView: MapView
        ) {
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: perspective
            )
            mapView.camera.ease(
                to: CameraOptions(
                    pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                ),
                duration: 0.25
            )
        }

        private func currentCameraOptions(from mapView: MapView) -> CameraOptions {
            let cameraState = mapView.mapboxMap.cameraState
            return CameraOptions(
                center: cameraState.center,
                padding: cameraState.padding,
                zoom: cameraState.zoom,
                bearing: cameraState.bearing,
                pitch: cameraState.pitch
            )
        }

        private func markerImage(
            routeCount: Int,
            isSelected: Bool,
            zoomStyle: RouteMapMarkerZoomStyle
        ) -> UIImage {
            let badgeVisible = routeCount > 1
            let cacheKey = MarkerImageCacheKey(
                routeCount: min(routeCount, 999),
                isSelected: isSelected,
                zoomBucket: zoomStyle.cacheBucket
            )
            if let cachedImage = markerImageCache[cacheKey] {
                return cachedImage
            }

            let size = CGSize(
                width: max(zoomStyle.outerDiameter + zoomStyle.badgeOffset.width + 18, zoomStyle.outerDiameter + 10),
                height: max(zoomStyle.outerDiameter + 10, zoomStyle.outerDiameter + abs(zoomStyle.badgeOffset.height) + 16)
            )
            let renderer = UIGraphicsImageRenderer(size: size)

            let image = renderer.image { context in
                let center = CGPoint(
                    x: (zoomStyle.outerDiameter / 2) + 4,
                    y: size.height - (zoomStyle.outerDiameter / 2) - 4
                )
                let outerRect = CGRect(
                    x: center.x - (zoomStyle.outerDiameter / 2),
                    y: center.y - (zoomStyle.outerDiameter / 2),
                    width: zoomStyle.outerDiameter + (isSelected ? 4 : 0),
                    height: zoomStyle.outerDiameter + (isSelected ? 4 : 0)
                )

                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 2),
                    blur: 6,
                    color: UIColor.black.withAlphaComponent(isSelected ? 0.22 : 0.12).cgColor
                )

                let outerFill = UIColor(red: 0.14, green: 0.15, blue: 0.18, alpha: 1)
                context.cgContext.setFillColor(outerFill.cgColor)
                context.cgContext.fillEllipse(in: outerRect)
                context.cgContext.setStrokeColor(
                    (isSelected ? UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 1) : UIColor.white.withAlphaComponent(0.18)).cgColor
                )
                context.cgContext.setLineWidth(zoomStyle.strokeWidth)
                context.cgContext.strokeEllipse(in: outerRect)

                let coreRect = CGRect(
                    x: center.x - (zoomStyle.coreDiameter / 2),
                    y: center.y - (zoomStyle.coreDiameter / 2),
                    width: zoomStyle.coreDiameter,
                    height: zoomStyle.coreDiameter
                )
                context.cgContext.setFillColor(
                    (isSelected ? UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 1) : UIColor.white.withAlphaComponent(0.66)).cgColor
                )
                context.cgContext.fillEllipse(in: coreRect)

                guard badgeVisible else {
                    return
                }

                let badgeText = "\(routeCount)" as NSString
                let font = UIFont.systemFont(
                    ofSize: zoomStyle == .close ? 12 : 10,
                    weight: .bold
                )
                let textAttributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white
                ]
                let textSize = badgeText.size(withAttributes: textAttributes)
                let badgeRect = CGRect(
                    x: center.x + zoomStyle.badgeOffset.width - 2,
                    y: center.y + zoomStyle.badgeOffset.height - 2,
                    width: textSize.width + (zoomStyle.badgeHorizontalPadding * 2),
                    height: textSize.height + (zoomStyle.badgeVerticalPadding * 2)
                )

                let badgePath = UIBezierPath(
                    roundedRect: badgeRect,
                    cornerRadius: badgeRect.height / 2
                )
                UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 1).setFill()
                badgePath.fill()

                let textOrigin = CGPoint(
                    x: badgeRect.midX - (textSize.width / 2),
                    y: badgeRect.midY - (textSize.height / 2)
                )
                badgeText.draw(at: textOrigin, withAttributes: textAttributes)
            }

            markerImageCache[cacheKey] = image
            return image
        }

        private static func cameraRegionKey(for region: MKCoordinateRegion) -> String {
            [
                region.center.latitude,
                region.center.longitude,
                region.span.latitudeDelta,
                region.span.longitudeDelta
            ]
            .map { String(format: "%.5f", $0) }
            .joined(separator: "|")
        }
    }
}

private struct RouteMapBrowseFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var presentedRoute: RouteRecord?

    let filteredRoutes: [RouteRecord]
    @Binding var requestedRegion: MKCoordinateRegion?
    @Binding var visibleRegion: MKCoordinateRegion?
    let fallbackRegion: MKCoordinateRegion?
    @Binding var selectedRouteID: Int?
    @Binding var selectedMarkerGroupID: String?
    @Binding var centerOnUserRequestID: Int
    @Binding var fitRequestID: Int
    let markerGroups: [RouteStartMarkerGroup]
    let appRouteMapStyle: AppRouteMapStyle
    let appRouteMapPerspective: AppRouteMapPerspective
    let markerZoomStyle: RouteMapMarkerZoomStyle
    let onCameraRegionChanged: (MKCoordinateRegion) -> Void
    let onSelectMarkerGroup: (RouteStartMarkerGroup) -> Void
    let onTapMapBackground: () -> Void
    let onSelectRoute: (RouteRecord) -> Void

    private var selectedRoute: RouteRecord? {
        guard let selectedRouteID else {
            return nil
        }

        return filteredRoutes.first(where: { $0.stravaRouteID == selectedRouteID })
    }

    private var selectedMarkerGroup: RouteStartMarkerGroup? {
        if let selectedMarkerGroupID,
           let matchedGroup = markerGroups.first(where: { $0.id == selectedMarkerGroupID }) {
            return matchedGroup
        }

        guard let selectedRouteID else {
            return nil
        }

        return markerGroups.first { group in
            group.routes.contains(where: { $0.stravaRouteID == selectedRouteID })
        }
    }

    private var displayedMarkerGroups: [RouteStartMarkerGroup] {
        if let selectedMarkerGroup {
            return [selectedMarkerGroup]
        }

        return markerGroups
    }

    var body: some View {
        ZStack(alignment: .top) {
            RouteMapBrowseCanvas(
                requestedRegion: $requestedRegion,
                visibleRegion: $visibleRegion,
                fallbackRegion: fallbackRegion,
                centerOnUserRequestID: $centerOnUserRequestID,
                fitRequestID: $fitRequestID,
                markerGroups: displayedMarkerGroups,
                selectedRoute: selectedRoute,
                selectedRouteID: selectedRouteID,
                markerZoomStyle: markerZoomStyle,
                appRouteMapStyle: appRouteMapStyle,
                appRouteMapPerspective: appRouteMapPerspective,
                onCameraRegionChanged: onCameraRegionChanged,
                onSelectMarkerGroup: onSelectMarkerGroup,
                onTapMapBackground: onTapMapBackground,
                controlsTopInset: 58
            ) { centerOnUserLocation in
                VStack(spacing: 10) {
                    RouteMapSettingsButton()

                    MapOverlayIconButton(
                        systemImage: "location.fill",
                        accessibilityLabel: "Center on your location"
                    ) {
                        centerOnUserLocation()
                    }
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    MapOverlayIconButton(systemImage: "xmark", accessibilityLabel: "Close full screen map") {
                        dismiss()
                    }

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                if let selectedMarkerGroup {
                    RouteMapSelectedGroupCarousel(
                        group: selectedMarkerGroup,
                        selectedRouteID: selectedRouteID,
                        onSelect: onSelectRoute,
                        onOpen: { route in
                            presentedRoute = route
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $presentedRoute) { route in
            NavigationStack {
                RouteEditorSheet(route: route)
            }
            .presentationDetents([.large])
        }
    }
}

private struct RouteStartMarkerGroup: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let routes: [RouteRecord]

    private struct ClusterAccumulator {
        var routes: [RouteRecord]
        private var latitudeTotal: Double
        private var longitudeTotal: Double

        init(route: RouteRecord, coordinate: CLLocationCoordinate2D) {
            routes = [route]
            latitudeTotal = coordinate.latitude
            longitudeTotal = coordinate.longitude
        }

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: latitudeTotal / Double(routes.count),
                longitude: longitudeTotal / Double(routes.count)
            )
        }

        mutating func append(route: RouteRecord, coordinate: CLLocationCoordinate2D) {
            routes.append(route)
            latitudeTotal += coordinate.latitude
            longitudeTotal += coordinate.longitude
        }
    }

    var annotationTitle: String {
        routes.count == 1 ? routes[0].name : "\(routes.count) starts"
    }

    func contains(routeID: Int?) -> Bool {
        guard let routeID else {
            return false
        }

        return routes.contains(where: { $0.stravaRouteID == routeID })
    }

    static func groups(from routes: [RouteRecord], region: MKCoordinateRegion?) -> [RouteStartMarkerGroup] {
        let clusterRadiusMeters = clusterRadiusMeters(for: region)
        var clusters: [ClusterAccumulator] = []

        let sortedRoutes = routes
            .compactMap { route -> (RouteRecord, CLLocationCoordinate2D)? in
                guard let coordinate = route.startCoordinate else {
                    return nil
                }

                return (route, coordinate)
            }
            .sorted { lhs, rhs in
                if lhs.1.latitude == rhs.1.latitude {
                    return lhs.1.longitude < rhs.1.longitude
                }

                return lhs.1.latitude < rhs.1.latitude
            }

        for (route, coordinate) in sortedRoutes {
            if let nearestClusterIndex = nearestClusterIndex(
                for: coordinate,
                in: clusters,
                clusterRadiusMeters: clusterRadiusMeters
            ) {
                clusters[nearestClusterIndex].append(route: route, coordinate: coordinate)
            } else {
                clusters.append(ClusterAccumulator(route: route, coordinate: coordinate))
            }
        }

        return clusters
            .map { cluster in
                let sortedRoutes = cluster.routes.sorted { lhs, rhs in
                    lhs.primaryTimestamp > rhs.primaryTimestamp
                }

                return RouteStartMarkerGroup(
                    id: groupID(for: sortedRoutes),
                    coordinate: cluster.coordinate,
                    routes: sortedRoutes
                )
            }
            .sorted { lhs, rhs in
                if lhs.routes.count == rhs.routes.count {
                    return (lhs.routes.first?.primaryTimestamp ?? .distantPast) >
                        (rhs.routes.first?.primaryTimestamp ?? .distantPast)
                }

                return lhs.routes.count > rhs.routes.count
            }
    }

    private static func nearestClusterIndex(
        for coordinate: CLLocationCoordinate2D,
        in clusters: [ClusterAccumulator],
        clusterRadiusMeters: CLLocationDistance
    ) -> Int? {
        guard !clusters.isEmpty else {
            return nil
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var bestIndex: Int?
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude

        for (index, cluster) in clusters.enumerated() {
            let clusterCoordinate = cluster.coordinate
            let clusterLocation = CLLocation(latitude: clusterCoordinate.latitude, longitude: clusterCoordinate.longitude)
            let distance = location.distance(from: clusterLocation)

            guard distance <= clusterRadiusMeters, distance < bestDistance else {
                continue
            }

            bestIndex = index
            bestDistance = distance
        }

        return bestIndex
    }

    private static func clusterRadiusMeters(for region: MKCoordinateRegion?) -> CLLocationDistance {
        guard let region else {
            return 50
        }

        let center = region.center
        let west = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude - (region.span.longitudeDelta / 2)
        )
        let east = CLLocation(
            latitude: center.latitude,
            longitude: center.longitude + (region.span.longitudeDelta / 2)
        )
        let south = CLLocation(
            latitude: center.latitude - (region.span.latitudeDelta / 2),
            longitude: center.longitude
        )
        let north = CLLocation(
            latitude: center.latitude + (region.span.latitudeDelta / 2),
            longitude: center.longitude
        )

        let dominantVisibleDistance = max(west.distance(from: east), south.distance(from: north))
        return min(max(dominantVisibleDistance * 0.035, 50), 18_000)
    }

    private static func groupID(for routes: [RouteRecord]) -> String {
        routes
            .map(\.stravaRouteID)
            .sorted()
            .map(String.init)
            .joined(separator: ":")
    }
}

private struct RouteMapMarkerAnnotation: View {
    @Environment(\.colorScheme) private var colorScheme
    let routeCount: Int
    let isSelected: Bool
    let zoomStyle: RouteMapMarkerZoomStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.18) : Color.white)
                        .frame(
                            width: zoomStyle.outerDiameter + (isSelected ? 4 : 0),
                            height: zoomStyle.outerDiameter + (isSelected ? 4 : 0)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected ? Color(red: 0.95, green: 0.48, blue: 0.26) : Color.primary.opacity(0.16),
                                    lineWidth: zoomStyle.strokeWidth
                                )
                        )

                    Circle()
                        .fill(isSelected ? Color(red: 0.95, green: 0.48, blue: 0.26) : Color.primary.opacity(0.66))
                        .frame(width: zoomStyle.coreDiameter, height: zoomStyle.coreDiameter)
                }
                .shadow(color: Color.black.opacity(isSelected ? 0.22 : 0.12), radius: 6, y: 2)

                if routeCount > 1 {
                    Text("\(routeCount)")
                        .font(zoomStyle.badgeFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, zoomStyle.badgeHorizontalPadding)
                        .padding(.vertical, zoomStyle.badgeVerticalPadding)
                        .background(Color(red: 0.95, green: 0.48, blue: 0.26), in: Capsule())
                        .offset(x: zoomStyle.badgeOffset.width, y: zoomStyle.badgeOffset.height)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RouteMapSelectedGroupCarousel: View {
    let group: RouteStartMarkerGroup
    let selectedRouteID: Int?
    let onSelect: (RouteRecord) -> Void
    let onOpen: (RouteRecord) -> Void

    private var effectiveSelectionID: Int {
        if let selectedRouteID,
           group.routes.contains(where: { $0.stravaRouteID == selectedRouteID }) {
            return selectedRouteID
        }

        return group.routes.first?.stravaRouteID ?? 0
    }

    private var effectiveSelectionIndex: Int {
        group.routes.firstIndex(where: { $0.stravaRouteID == effectiveSelectionID }) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.routes.count == 1 ? "Selected Start" : "\(group.routes.count) Routes From This Start")
                    .font(.headline)

                Spacer(minLength: 0)

                if group.routes.count > 1 {
                    Text("Swipe to compare")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            TabView(selection: selectionBinding) {
                ForEach(group.routes) { route in
                    RouteMapSelectedRouteCard(route: route) {
                        onOpen(route)
                    }
                    .tag(route.stravaRouteID)
                }
            }
            .frame(height: 130)
            .tabViewStyle(.page(indexDisplayMode: .never))

            if group.routes.count > 1 {
                if group.routes.count <= 10 {
                    HStack(spacing: 7) {
                        ForEach(group.routes) { route in
                            Circle()
                                .fill(route.stravaRouteID == effectiveSelectionID ? Color.white : Color.white.opacity(0.28))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                } else {
                    Text("\(effectiveSelectionIndex + 1) of \(group.routes.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var selectionBinding: Binding<Int> {
        Binding(
            get: { effectiveSelectionID },
            set: { newValue in
                guard let route = group.routes.first(where: { $0.stravaRouteID == newValue }) else {
                    return
                }

                onSelect(route)
            }
        )
    }
}

private struct DeferredSheetContent<Content: View>: View {
    @State private var hasAppeared = false
    let content: () -> Content

    var body: some View {
        Group {
            if hasAppeared {
                content()
            } else {
                Color.clear
                    .ignoresSafeArea()
                    .task {
                        hasAppeared = true
                    }
            }
        }
    }
}

private struct RouteMapSelectedRouteCard: View {
    let route: RouteRecord
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(route.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(route.displayLocation.nilIfEmpty ?? route.startCoordinate?.formattedLabel ?? "Location unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                Label(RouteDisplayFormatter.distance(route.distanceMeters), systemImage: "ruler")
                Label(RouteDisplayFormatter.climb(route.elevationGainMeters), systemImage: "mountain.2")
                HStack(spacing: 5) {
                    AppIconGlyph(name: route.sportSymbolName, size: 14, weight: .semibold)
                    Text(route.sportDisplayName)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .routePanelSurface(cornerRadius: 24)
    }
}

private extension MKCoordinateRegion {
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latitudeMin = center.latitude - (span.latitudeDelta / 2)
        let latitudeMax = center.latitude + (span.latitudeDelta / 2)
        let longitudeMin = center.longitude - (span.longitudeDelta / 2)
        let longitudeMax = center.longitude + (span.longitudeDelta / 2)

        return coordinate.latitude >= latitudeMin &&
            coordinate.latitude <= latitudeMax &&
            coordinate.longitude >= longitudeMin &&
            coordinate.longitude <= longitudeMax
    }
}

private struct RouteMapBrowseRow: View {
    let route: RouteRecord
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text(route.displayLocation.nilIfEmpty ?? route.startCoordinate?.formattedLabel ?? "Location unavailable")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? Color(red: 0.95, green: 0.48, blue: 0.26) : .secondary)
                    }

                    HStack(spacing: 12) {
                        Label(RouteDisplayFormatter.distance(route.distanceMeters), systemImage: "ruler")
                        Label(RouteDisplayFormatter.climb(route.elevationGainMeters), systemImage: "mountain.2")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isSelected {
                Button("Open Details", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .routeControlSurface(isActive: isSelected, cornerRadius: 22)
    }
}

private struct RouteOfflineCenterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue

    let visibleRoutes: [RouteRecord]

    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var selectedRoute: RouteRecord?
    @State private var processingCompletedCount = 0
    @State private var processingTotalCount = 0
    @State private var processingRouteID: Int?
    @State private var processingRouteName: String?
    @State private var processingProgress: RouteOfflineDownloadProgress?

    private let offlineAssetService = RouteOfflineAssetService()
    private let offlineDownloadCoordinator = RouteOfflineDownloadCoordinator()
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var visibleRouteEntries: [(route: RouteRecord, status: RouteOfflineAssetStatus)] {
        visibleRoutes.map { route in
            (route: route, status: offlineAssetService.offlineStatus(for: route))
        }
    }

    private var savedRoutes: [RouteRecord] {
        visibleRouteEntries
            .filter { $0.status.hasConcreteAssets }
            .map(\.route)
    }

    private var routesNeedingDownload: [RouteRecord] {
        visibleRouteEntries
            .filter { !$0.status.hasConcreteAssets }
            .map(\.route)
    }

    private var routesNeedingRefreshCount: Int {
        visibleRouteEntries.filter { $0.status.hasAnyAssets && !$0.status.hasConcreteAssets }.count
    }

    private var removableRoutes: [RouteRecord] {
        visibleRouteEntries
            .filter { $0.status.hasAnyAssets }
            .map(\.route)
    }

    private var totalOfflineBytes: Int64 {
        visibleRouteEntries.reduce(into: Int64(0)) { total, entry in
            total += entry.status.totalBytes
        }
    }

    private var processingFractionCompleted: Double {
        guard processingTotalCount > 0 else {
            return 0
        }

        let inFlightFraction = max(0, min(1, processingProgress?.fractionCompleted ?? 0))
        return min(1, (Double(processingCompletedCount) + inFlightFraction) / Double(processingTotalCount))
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    BannerView(message: errorMessage, tone: .error)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            if let statusMessage {
                Section {
                    BannerView(message: statusMessage, tone: .success)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section("Summary") {
                LabeledContent("Routes Matching Filters", value: "\(visibleRoutes.count)")
                LabeledContent("Routes With Offline Files", value: "\(savedRoutes.count)")
                if routesNeedingRefreshCount > 0 {
                    LabeledContent("Needs Refresh", value: "\(routesNeedingRefreshCount)")
                }
                LabeledContent("Cached Storage", value: byteCountFormatter.string(fromByteCount: totalOfflineBytes))
            }

            Section("Batch Actions") {
                Button {
                    Task { await cacheRoutes(routesNeedingDownload) }
                } label: {
                    Label("Download Missing Default Offline Files", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("offline-center-download-missing")
                .disabled(isProcessing || routesNeedingDownload.isEmpty)

                Button {
                    Task { await cacheRoutes(savedRoutes) }
                } label: {
                    Label("Refresh Saved Offline Files", systemImage: "arrow.clockwise.circle")
                }
                .accessibilityIdentifier("offline-center-refresh-saved")
                .disabled(isProcessing || savedRoutes.isEmpty)

                Button(role: .destructive) {
                    removeOfflineAssets(for: removableRoutes)
                } label: {
                    Label("Remove Saved Offline Files", systemImage: "trash")
                }
                .accessibilityIdentifier("offline-center-remove-saved")
                .disabled(isProcessing || removableRoutes.isEmpty)

                if isProcessing {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(processingRouteName.map { "Updating \($0)" } ?? "Updating offline files")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            Text("\(processingCompletedCount)/\(max(processingTotalCount, 1))")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            if let percentageText = processingProgress?.percentageText {
                                Text(percentageText)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ProgressView(value: processingFractionCompleted, total: 1)

                        Text(processingProgress?.message ?? "Route-by-route progress for the current batch action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Batch downloads save the default bundle: GPX + Outdoors map. Open a route to choose different map styles or terrain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(visibleRoutes.isEmpty ? "Routes Matching Filters" : "Routes Matching Filters (\(visibleRoutes.count))") {
                if visibleRoutes.isEmpty {
                    ContentUnavailableView(
                        "No Routes Match Current Filters",
                        systemImage: "tray",
                        description: Text("Adjust your filters or sync more routes to manage them offline.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(visibleRouteEntries, id: \.route.stravaRouteID) { entry in
                        let route = entry.route
                        RouteOfflineRow(
                            route: route,
                            offlineStatus: entry.status,
                            byteText: byteCountFormatter.string(fromByteCount: entry.status.totalBytes),
                            gpxURL: entry.status.hasGPX ? offlineAssetService.gpxURL(for: route) : nil,
                            isActionDisabled: isProcessing,
                            downloadProgress: processingRouteID == route.stravaRouteID ? processingProgress : nil,
                            onDownload: {
                                Task { await cacheRoutes([route]) }
                            },
                            onRemove: {
                                removeOfflineAssets(for: [route])
                            },
                            onOpen: {
                                selectedRoute = route
                            }
                        )
                    }
                }
            }
        }
        .id("offline-center-\(appMeasurementSystemRawValue)")
        .navigationTitle("Offline Center")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("offline-center-screen")
        .sheet(item: $selectedRoute) { route in
            NavigationStack {
                RouteEditorSheet(
                    route: route,
                    onDelete: { routeToDelete in
                        modelContext.delete(routeToDelete)
                        try? modelContext.save()
                        selectedRoute = nil
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") {
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    @MainActor
    private func cacheRoutes(_ routes: [RouteRecord]) async {
        guard !routes.isEmpty else {
            statusMessage = "No routes were selected for offline download."
            return
        }

        guard !isProcessing else {
            statusMessage = processingRouteName.map {
                "Offline files are already updating for \($0)."
            } ?? "Offline files are already updating."
            return
        }

        isProcessing = true
        statusMessage = nil
        errorMessage = nil
        processingCompletedCount = 0
        processingTotalCount = routes.count
        processingRouteID = routes.first?.stravaRouteID
        processingRouteName = routes.first?.name
        processingProgress = nil

        var completed = 0
        var failures: [String] = []

        for route in routes {
            processingRouteID = route.stravaRouteID
            processingRouteName = route.name
            processingProgress = nil

            do {
                let storedAssets = try await offlineDownloadCoordinator.storeOfflineBundle(
                    for: route,
                    progress: { progress in
                        Task { @MainActor in
                            processingProgress = progress
                        }
                    }
                )
                route.offlineGPXRelativePath = storedAssets.gpxRelativePath
                route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
                route.offlineDownloadedAt = storedAssets.downloadedAt
                completed += 1
            } catch {
                failures.append("\(route.name): \(error.localizedDescription)")
            }

            processingCompletedCount += 1
            processingProgress = nil
        }

        try? modelContext.save()

        if completed > 0 {
            statusMessage = completed == 1
                ? "Saved offline files for 1 route."
                : "Saved offline files for \(completed) routes."
        }

        if !failures.isEmpty {
            errorMessage = failures.count == 1
                ? failures[0]
                : "\(failures.count) routes could not be saved offline. \(failures[0])"
        }

        isProcessing = false
        processingCompletedCount = 0
        processingTotalCount = 0
        processingRouteID = nil
        processingRouteName = nil
        processingProgress = nil
    }

    private func removeOfflineAssets(for routes: [RouteRecord]) {
        guard !routes.isEmpty else {
            return
        }

        guard !isProcessing else {
            statusMessage = "Wait for the current offline update to finish before removing files."
            return
        }

        var removedCount = 0

        for route in routes where offlineAssetService.offlineStatus(for: route).hasAnyAssets {
            do {
                try offlineAssetService.removeOfflineAssets(for: route)
                route.offlineGPXRelativePath = nil
                route.offlineMapSnapshotRelativePath = nil
                route.offlineDownloadedAt = nil
                removedCount += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        try? modelContext.save()

        if removedCount > 0 {
            statusMessage = removedCount == 1
                ? "Removed offline files from 1 route."
                : "Removed offline files from \(removedCount) routes."
        }
    }
}

private struct RouteOfflineRow: View {
    let route: RouteRecord
    let offlineStatus: RouteOfflineAssetStatus
    let byteText: String
    let gpxURL: URL?
    let isActionDisabled: Bool
    let downloadProgress: RouteOfflineDownloadProgress?
    let onDownload: () -> Void
    let onRemove: () -> Void
    let onOpen: () -> Void

    private var offlineStatusLabel: String {
        if offlineStatus.hasConcreteAssets {
            return "Saved"
        }

        if offlineStatus.hasAnyAssets {
            return "Needs Refresh"
        }

        return "Not Saved"
    }

    private var offlineStatusColor: Color {
        if offlineStatus.hasConcreteAssets {
            return .green
        }

        if offlineStatus.hasAnyAssets {
            return .orange
        }

        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(route.displayLocation.nilIfEmpty ?? route.startCoordinate?.formattedLabel ?? "Location unavailable")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(offlineStatusLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(offlineStatusColor)
            }

            Text(offlineStatus.summaryText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(offlineStatus.hasConcreteAssets ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if offlineStatus.hasConcreteAssets {
                RouteOfflineAssetPills(labels: offlineStatus.componentLabels)
            }

            if let downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(downloadProgress.message)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        if let percentageText = downloadProgress.percentageText {
                            Text(percentageText)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fractionCompleted = downloadProgress.fractionCompleted {
                        ProgressView(value: fractionCompleted, total: 1)
                    } else {
                        ProgressView()
                    }
                }
            }

            HStack(spacing: 12) {
                Label(RouteDisplayFormatter.distance(route.distanceMeters), systemImage: "ruler")
                Label(offlineStorageText, systemImage: "externaldrive")
                if let downloadedAt = offlineStatus.downloadedAt {
                    Label("Updated \(RouteDisplayFormatter.calendarDate(downloadedAt))", systemImage: "clock")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if offlineStatus.hasConcreteAssets {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Refresh saved offline route")
                    .accessibilityIdentifier("offline-row-refresh-\(route.stravaRouteID)")
                    .disabled(isActionDisabled)
                } else {
                    Button(downloadProgress == nil ? "Download" : "Downloading…", action: onDownload)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("offline-row-download-\(route.stravaRouteID)")
                        .disabled(isActionDisabled)
                }

                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("offline-row-open-\(route.stravaRouteID)")

                if offlineStatus.hasAnyAssets {
                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("offline-row-remove-\(route.stravaRouteID)")
                        .disabled(isActionDisabled)
                }

                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Share GPX")
                    .accessibilityIdentifier("offline-row-share-gpx-\(route.stravaRouteID)")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("offline-row-\(route.stravaRouteID)")
    }

    private var offlineStorageText: String {
        guard offlineStatus.totalBytes > 0 else {
            return offlineStatus.hasAnyAssets ? "Needs refresh" : "Not saved"
        }

        return byteText
    }
}

private struct RouteOfflineAssetPills: View {
    let labels: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
    }
}

private enum RouteSpotlightIdentifier {
    private static let routePrefix = "route:"

    case route(Int)

    static func routeIdentifier(for route: RouteRecord) -> String {
        "\(routePrefix)\(route.stravaRouteID)"
    }

    static func parse(_ identifier: String) -> RouteSpotlightIdentifier? {
        if identifier.hasPrefix(routePrefix),
           let routeID = Int(identifier.dropFirst(routePrefix.count)) {
            return .route(routeID)
        }

        return nil
    }
}

private enum RouteSpotlightIndexer {
    static func reindex(routes: [RouteRecord]) async {
        let searchableIndex = CSSearchableIndex.default()

        do {
            try await delete(domainIdentifiers: ["com.myaport.RouteVault.routeLibrary"], from: searchableIndex)
            let items = searchableItems(routes: routes)
            guard !items.isEmpty else {
                return
            }

            try await add(items: items, to: searchableIndex)
        } catch {
            // Search indexing should not block the route library experience.
        }
    }

    private static func searchableItems(routes: [RouteRecord]) -> [CSSearchableItem] {
        routes.map { route -> CSSearchableItem in
            let attributeSet = CSSearchableItemAttributeSet(contentType: .item)
            attributeSet.title = route.name
            attributeSet.contentDescription = [
                route.displayLocation.nilIfEmpty,
                route.sportDisplayName,
                RouteDisplayFormatter.distance(route.distanceMeters),
                RouteDisplayFormatter.climb(route.elevationGainMeters),
                route.notes.trimmed.nilIfEmpty
            ]
            .compactMap { $0 }
            .joined(separator: " • ")
            attributeSet.keywords = route.searchKeywords
            return CSSearchableItem(
                uniqueIdentifier: RouteSpotlightIdentifier.routeIdentifier(for: route),
                domainIdentifier: "com.myaport.RouteVault.routeLibrary",
                attributeSet: attributeSet
            )
        }
    }

    private static func add(items: [CSSearchableItem], to index: CSSearchableIndex) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func delete(domainIdentifiers: [String], from index: CSSearchableIndex) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

private extension View {
    func routePanelSurface(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    func routeControlSurface(isActive: Bool, cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    isActive
                        ? .regular.tint(Color(red: 0.95, green: 0.63, blue: 0.48)).interactive()
                        : .regular.interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isActive ? Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isActive ? Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.35) : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private extension UTType {
    static var gpxRoute: UTType {
        UTType(filenameExtension: "gpx") ?? .xml
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
