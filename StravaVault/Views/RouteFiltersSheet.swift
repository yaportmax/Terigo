import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteFiltersSheet: View {
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
                        RouteRangePanel(
                            model: model,
                            kind: .distance,
                            sliderBounds: distanceSliderBounds,
                            filteredBounds: filteredDistanceBounds
                        )

                        Divider()
                            .overlay(Color.primary.opacity(0.08))
                            .padding(.vertical, 2)

                        RouteRangePanel(
                            model: model,
                            kind: .climb,
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

