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
