import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteResultsSection: View {
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
    var emptyListName: String? = nil

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
                    Label(routeCount == 0 ? (emptyListName == nil ? "Your next route starts here" : "Ready for your routes") : "No matching routes", systemImage: routeCount == 0 ? "map" : "magnifyingglass")
                } description: {
                    Text(isSyncing ? "Your routes are syncing from Strava." : (routeCount == 0 ? emptyListName.map { "Open a route in your library and add it to \($0) under Lists." } ?? "Tap + to import a GPX file, or connect Strava to bring your routes with you." : "Try another search or clear your filters."))
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
struct RouteOfflineDownloadCoordinator {
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
        let selectedMapStyles: [AppRouteMapStyle] = RouteVaultMapboxConfiguration.isConfigured
            ? (hasConcreteAssets ? offlineStatus.mapStyles : [.outdoors]) : []

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
    @State private var isShowingDeleteConfirmation = false
    @State private var isDownloadingOffline = false

    private var offlineStatus: RouteOfflineAssetStatus {
        offlineAssetService.offlineStatus(for: route)
    }

    var body: some View {
        RouteCardView(route: route, density: density, onSelect: onSelect)
            .contextMenu { quickActionMenu }
            .overlay(alignment: .topTrailing) {
                Menu { quickActionMenu } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(TerigoTheme.surface, in: Circle())
                }
                .tint(.secondary)
                .accessibilityLabel("Actions for \(route.name)")
                .accessibilityIdentifier("route-actions-\(route.stravaRouteID)")
                .padding(density == .compact ? 0 : density.contentPadding)
            }
            .sheet(isPresented: $isShowingCreateListSheet) {
                NavigationStack {
                    QuickCreateListSheet { listName in createListAndAddRoute(named: listName) }
                }
                .presentationDetents([.medium])
            }
        .alert("Delete Route?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete Route", role: .destructive) { onDeleteRoute(route) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the route and its saved offline files from your library.")
        }
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
            isShowingDeleteConfirmation = true
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
            if !route.hasList(named: existingList.name) {
                toggleList(existingList)
            }
            return
        }

        let previousListNames = route.listNames
        let newList = RouteList(name: trimmedListName)
        modelContext.insert(newList)
        route.listNames = route.toggledListNames(with: newList.name)
        do {
            try modelContext.save()
            onReportStatus("Created \(newList.name) and added \(route.name).")
        } catch {
            route.listNames = previousListNames
            modelContext.delete(newList)
            onReportError("Couldn’t create the list. \(error.localizedDescription)")
        }
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
            try modelContext.save()
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
            try modelContext.save()
            onReportStatus("Removed offline files for \(route.name).")
        } catch {
            onReportError(error.localizedDescription)
        }
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
