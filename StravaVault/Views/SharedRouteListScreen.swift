import SwiftData
import SwiftUI

private enum SharedRouteDownloadError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This shared route is not currently downloadable."
        }
    }
}

struct SharedRouteListScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RouteVaultAccountManager.self) private var accountManager

    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var allRoutes: [RouteRecord]
    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var allLists: [RouteList]

    let shareToken: String

    @State private var payload: RouteVaultSharedListPayload?
    @State private var isLoading = false
    @State private var isFollowing = false
    @State private var isDownloadingAll = false
    @State private var routeDownloadIDs = Set<Int>()
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private let backendService = RouteVaultBackendService()
    private let gpxImportService = GPXImportService()
    private let offlineAssetService = RouteOfflineAssetService()

    var body: some View {
        List {
            if let errorMessage = errorMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let statusMessage = statusMessage?.trimmed.nilIfEmpty {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let payload {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(payload.name)
                            .font(.title2.weight(.bold))
                        Text("By \(payload.ownerDisplayName)")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        if let listDescription = payload.listDescription.trimmed.nilIfEmpty {
                            Text(listDescription)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        Text("Updated \(payload.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Actions") {
                    Button {
                        Task { await followList() }
                    } label: {
                        Label(
                            isAlreadyFollowing ? "Already In Your Library" : (isFollowing ? "Saving…" : "Save List To Your Library"),
                            systemImage: isAlreadyFollowing ? "checkmark.circle" : "square.and.arrow.down"
                        )
                    }
                    .disabled(
                        isFollowing ||
                        isAlreadyFollowing ||
                        !accountManager.canUseBackendFeatures ||
                        payload.visibility != RouteListVisibilityMode.linkView.rawValue
                    )

                    Button {
                        Task { await downloadAllAvailableRoutes() }
                    } label: {
                        Label(
                            isDownloadingAll ? "Downloading Routes…" : "Download Available Routes",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(hasActiveDownloads || downloadableRoutes.isEmpty)
                }

                Section(downloadableRoutes.isEmpty ? "Routes" : "Routes (\(downloadableRoutes.count) downloadable)") {
                    ForEach(payload.routes) { route in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(route.name)
                                        .font(.headline)
                                    Text(route.displayLocation)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(routeMetricLine(route))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                if route.isDownloadable {
                                    Button {
                                        Task { await downloadRoute(route) }
                                    } label: {
                                        Label(
                                            (isDownloadingAll || routeDownloadIDs.contains(route.id)) ? "Downloading…" : "Download",
                                            systemImage: "arrow.down"
                                        )
                                        .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isDownloadingAll || routeDownloadIDs.contains(route.id))
                                }
                            }

                            if let shareabilityMessage = route.shareabilityMessage?.trimmed.nilIfEmpty {
                                Text(shareabilityMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading shared list…")
                    }
                }
            } else {
                Section {
                    Text("This shared list could not be loaded.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Shared List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            await loadSharedList()
        }
    }

    private var isAlreadyFollowing: Bool {
        allLists.contains {
            $0.remoteListID == payload?.listID || (
                $0.remoteAccessRole == .follower &&
                $0.remoteShareToken == shareToken
            )
        }
    }

    private var downloadableRoutes: [RouteVaultSharedRoutePayload] {
        payload?.routes.filter(\.isDownloadable) ?? []
    }

    private var hasActiveDownloads: Bool {
        isDownloadingAll || !routeDownloadIDs.isEmpty
    }

    private func routeMetricLine(_ route: RouteVaultSharedRoutePayload) -> String {
        let distance = Measurement(value: route.distanceMeters, unit: UnitLength.meters)
            .converted(to: .miles)
            .value
        let climb = Measurement(value: route.elevationGainMeters, unit: UnitLength.meters)
            .converted(to: .feet)
            .value
        return "\(distance.formatted(.number.precision(.fractionLength(1)))) mi • \(Int(climb.rounded())) ft • \(route.sportKind)"
    }

    @MainActor
    private func loadSharedList() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            payload = try await backendService.fetchSharedList(
                shareToken: shareToken,
                accountSessionToken: accountManager.accountSession?.token
            )
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    @MainActor
    private func followList() async {
        guard !isFollowing,
              let payload,
              let accountSession = accountManager.accountSession else {
            return
        }

        isFollowing = true
        defer { isFollowing = false }

        do {
            try await backendService.setFollowState(
                shareToken: shareToken,
                isFollowing: true,
                accountSessionToken: accountSession.token
            )

            let list = upsertFollowedList(from: payload)
            try modelContext.save()
            statusMessage = "Saved \(list.name) to your library."
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    @MainActor
    private func downloadAllAvailableRoutes() async {
        guard !isDownloadingAll,
              !downloadableRoutes.isEmpty,
              routeDownloadIDs.isEmpty else {
            return
        }

        let bulkRouteIDs = Set(downloadableRoutes.map(\.id))
        isDownloadingAll = true
        routeDownloadIDs.formUnion(bulkRouteIDs)
        defer {
            routeDownloadIDs.subtract(bulkRouteIDs)
            isDownloadingAll = false
        }

        var importedCount = 0
        var failureMessages: [String] = []

        for route in downloadableRoutes {
            do {
                try await importSharedRoute(route)
                importedCount += 1
            } catch {
                failureMessages.append(displayMessage(for: error))
            }
        }

        if importedCount > 0 {
            statusMessage = importedCount == 1
                ? "Downloaded 1 route from the shared list."
                : "Downloaded \(importedCount) routes from the shared list."
        }

        if let firstFailure = failureMessages.first {
            errorMessage = failureMessages.count == 1 ? firstFailure : "\(failureMessages.count) route downloads failed. \(firstFailure)"
        } else {
            errorMessage = nil
        }
    }

    @MainActor
    private func downloadRoute(_ route: RouteVaultSharedRoutePayload) async {
        guard !isDownloadingAll,
              !routeDownloadIDs.contains(route.id) else {
            return
        }

        routeDownloadIDs.insert(route.id)
        defer { routeDownloadIDs.remove(route.id) }

        do {
            try await importSharedRoute(route)
            statusMessage = "Downloaded \(route.name)."
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    @MainActor
    private func importSharedRoute(_ route: RouteVaultSharedRoutePayload) async throws {
        guard let downloadURL = route.downloadURL else {
            throw SharedRouteDownloadError.unavailable
        }

        let gpxData = try await backendService.downloadSharedRouteGPX(from: downloadURL)
        let importedRoute = try await gpxImportService.importRoute(from: gpxData, suggestedName: route.name)

        let targetRoute: RouteRecord
        if let existingRoute = allRoutes.first(where: { $0.stravaRouteID == route.stravaRouteID }) {
            existingRoute.applyImportedGeometry(importedRoute)
            targetRoute = existingRoute
        } else {
            let newRoute = RouteRecord(importedGPX: importedRoute, syncedAt: .now)
            newRoute.stravaRouteID = route.stravaRouteID
            newRoute.name = route.name
            newRoute.routeDescription = route.routeDescription
            newRoute.distanceMeters = route.distanceMeters
            newRoute.elevationGainMeters = route.elevationGainMeters
            newRoute.estimatedMovingTime = route.estimatedMovingTime
            modelContext.insert(newRoute)
            targetRoute = newRoute
        }

        let storedAssets = try await offlineAssetService.storeOfflineAssets(for: targetRoute, gpxData: gpxData, mapStyle: .outdoors)
        targetRoute.offlineGPXRelativePath = storedAssets.gpxRelativePath
        targetRoute.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
        targetRoute.offlineDownloadedAt = storedAssets.downloadedAt

        if let payload,
           let list = allLists.first(where: {
               $0.remoteListID == payload.listID || (
                   $0.remoteAccessRole == .follower &&
                   $0.remoteShareToken == shareToken
               )
           }) {
            targetRoute.listNames = RouteRecord.normalizedLabels(targetRoute.listNames + [list.name])
        }

        try modelContext.save()
    }

    private func upsertFollowedList(from payload: RouteVaultSharedListPayload) -> RouteList {
        if let existingList = allLists.first(where: {
            $0.remoteListID == payload.listID || (
                $0.remoteAccessRole == .follower &&
                $0.remoteShareToken == shareToken
            )
        }) {
            applyRemotePayload(payload, to: existingList)
            return existingList
        }

        let list = RouteList(
            name: uniqueListName(payload.name),
            listDescription: payload.listDescription,
            shareCode: RouteList.makeShareCode(),
            sharingVisibility: RouteListVisibilityMode(rawValue: payload.visibility),
            collaborationMode: RouteListCollaborationMode(rawValue: payload.collaborationMode) ?? .ownerOnly,
            remoteListID: payload.listID,
            remoteOwnerAccountID: nil,
            remoteOwnerDisplayName: payload.ownerDisplayName,
            remoteShareToken: shareToken,
            remoteAccessRole: .follower,
            remoteRevision: payload.revision,
            lastRemoteSyncAt: payload.updatedAt,
            collaboratorCodes: payload.collaboratorCodes,
            viewerCodes: payload.viewerCodes,
            importedRouteReferences: payload.routes.map {
                RouteListSharedRouteReference(routeID: $0.stravaRouteID, name: $0.name)
            }
        )
        modelContext.insert(list)
        applyMemberships(for: list, routeIDs: Set(payload.routes.map(\.stravaRouteID)))
        return list
    }

    private func applyRemotePayload(_ payload: RouteVaultSharedListPayload, to list: RouteList) {
        let previousName = list.name
        let mergedName = uniqueListName(
            payload.name,
            excluding: allLists
                .filter { $0.id != list.id }
                .map(\.name)
        )

        list.name = mergedName
        list.listDescription = payload.listDescription
        list.sharingVisibility = RouteListVisibilityMode(rawValue: payload.visibility) ?? .linkView
        list.collaborationMode = RouteListCollaborationMode(rawValue: payload.collaborationMode) ?? .ownerOnly
        list.collaboratorCodes = payload.collaboratorCodes
        list.viewerCodes = payload.viewerCodes
        list.remoteListID = payload.listID
        list.remoteOwnerDisplayName = payload.ownerDisplayName
        list.remoteShareToken = shareToken
        list.remoteAccessRole = .follower
        list.remoteRevision = payload.revision
        list.lastRemoteSyncAt = payload.updatedAt
        list.importedRouteReferences = payload.routes.map {
            RouteListSharedRouteReference(routeID: $0.stravaRouteID, name: $0.name)
        }
        list.updatedAt = payload.updatedAt

        let routeIDs = Set(payload.routes.map(\.stravaRouteID))
        for route in allRoutes {
            if routeIDs.contains(route.stravaRouteID) {
                var labels = route.listNames
                if previousName != mergedName {
                    labels = route.removingList(named: previousName)
                }
                route.listNames = RouteRecord.normalizedLabels(labels + [mergedName])
            } else if route.hasList(named: previousName) {
                route.listNames = route.removingList(named: previousName)
            }
        }

        let currentRoutes = allRoutes.filter { $0.hasList(named: list.name) }
        list.lastRemoteSyncFingerprint = RouteVaultListSyncService().fingerprint(for: list, routes: currentRoutes)
    }

    private func applyMemberships(for list: RouteList, routeIDs: Set<Int>) {
        for route in allRoutes where routeIDs.contains(route.stravaRouteID) {
            route.listNames = RouteRecord.normalizedLabels(route.listNames + [list.name])
        }
    }

    private func uniqueListName(_ baseName: String, excluding existingNames: [String]? = nil) -> String {
        let names = existingNames ?? allLists.map(\.name)
        let normalizedExistingNames = Set(names.map(\.routeLabelIdentifier))
        let trimmedBaseName = baseName.trimmed.nilIfEmpty ?? "Shared List"
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

    private func displayMessage(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }
}
