import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteLibraryScreen: View {
    private enum Tab: Hashable {
        case routes, explore, lists, activities
    }

    private struct PresentedSharedList: Identifiable, Equatable {
        let shareToken: String

        var id: String { shareToken }
    }

    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.system.rawValue
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
    @State private var isShowingAccountSettings = false
    @State private var isShowingFeedbackSheet = false
    @State private var selectedTab: Tab = .routes
    @State private var presentedSharedList: PresentedSharedList?
    @State private var statusBannerDismissTask: Task<Void, Never>?
    @State private var selectedRoutePresentationDetent: PresentationDetent = .large
    @State private var didApplyScreenshotPresentation = false

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
        TabView(selection: $selectedTab) {
            NavigationStack {
                libraryScrollContent
                    .navigationTitle("Routes")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Image("TerigoMark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .accessibilityLabel("Terigo")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                private var libraryScrollContent: some View {
        let filteredRoutes = model.filteredRoutes(from: routes)

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

                if !model.isConnected && !routes.isEmpty {
                    ConnectionSection(model: model)
                }

                if !routes.isEmpty {
                    ControlsSection(
                        model: model,
                        allRoutes: routes,
                        lists: sortedRouteLists
                    )
                    .id("controls-\(appMeasurementSystemRawValue)")
                }

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
                        do {
                            try modelContext.save()
                            model.errorMessage = nil
                        } catch {
                            model.errorMessage = "Couldn’t save the list change. \(error.localizedDescription)"
                        }
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

                if !model.isConnected && routes.isEmpty {
                    ConnectionSection(model: model)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(TerigoTheme.background.ignoresSafeArea())
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

        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }
        var encounteredConflict = false

        for list in routeLists {
            guard !Task.isCancelled else { return }
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
        saveLibraryChanges()
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
                    selectedTab = .activities
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

            Section("Help") {
                Button {
                    isShowingFeedbackSheet = true
                } label: {
                    Label("Send Feedback", systemImage: "bubble.left")
                }
                .accessibilityIdentifier("route-library-send-feedback")
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
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
            get: { AppAppearance(rawValue: appAppearanceRawValue) ?? .system },
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
            selectedTab = .explore
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

    private func deleteListEverywhere(_ list: RouteList) -> Bool {
        let listToken = list.name.routeLabelIdentifier
        guard !listToken.isEmpty else {
            return false
        }

        // Commit earlier edits first so rollback only restores this deletion.
        guard saveLibraryChanges() else { return false }
        let listName = list.name
        let followedShareToken = list.remoteAccessRole == .follower ? list.remoteShareToken?.trimmed.nilIfEmpty : nil

        for route in routes where route.hasList(named: listName) {
            route.listNames = route.removingList(named: listName)
        }
        modelContext.delete(list)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            model.errorMessage = "Couldn’t delete the list. \(error.localizedDescription)"
            return false
        }

        model.removeSelectedTag(listName)
        if let shareToken = followedShareToken, let accountSession = accountManager.accountSession {
            Task {
                do {
                    try await RouteVaultBackendService().setFollowState(
                        shareToken: shareToken,
                        isFollowing: false,
                        accountSessionToken: accountSession.token
                    )
                } catch {
                    accountManager.errorMessage = "The list was removed locally, but unfollowing failed. \(error.localizedDescription)"
                }
            }
        }
        return true
    }

    @discardableResult
    private func saveLibraryChanges() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            model.errorMessage = "Couldn’t save library changes. \(error.localizedDescription)"
            return false
        }
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

        saveLibraryChanges()
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
            selectedTab = .lists
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
