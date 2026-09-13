import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ControlsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: RouteLibraryModel
    let allRoutes: [RouteRecord]
    let lists: [RouteList]

    @State private var searchDraft = ""
    @State private var isShowingSortSheet = false
    @State private var isShowingFiltersSheet = false
    @State private var didApplyScreenshotPresentation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchField(
                text: $searchDraft,
                placeholder: "Search routes, places, notes…"
            )
            .zIndex(0)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
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

            HStack {
                Text("\(model.filteredRoutes(from: allRoutes).count) \(model.filteredRoutes(from: allRoutes).count == 1 ? "route" : "routes")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(sortChipValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !filterTokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filterTokens) { token in
                            Button(action: token.clear) {
                                HStack(spacing: 6) {
                                    Text(token.value.isEmpty ? token.title : token.value)
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(TerigoTheme.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(token.title) filter: \(token.value)")
                        }
                    }
                }
            }
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
        .task(id: searchDraft) {
            guard searchDraft != model.query else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            model.query = searchDraft
        }
        .onChange(of: model.query) { _, query in
            if searchDraft != query { searchDraft = query }
        }
        .onAppear {
            searchDraft = model.query
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

