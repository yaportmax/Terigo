import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteMapBrowseSheet: View {
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
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height
            let layout = isWide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            layout {
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
                    let controlsLayout = isWide
                        ? AnyLayout(HStackLayout(spacing: 8))
                        : AnyLayout(VStackLayout(spacing: 10))
                    controlsLayout {
                        RouteMapSettingsButton()

                        MapOverlayIconButton(
                            systemImage: "scope",
                            accessibilityLabel: "Fit routes on map",
                            action: fitToResults
                        )

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
                .frame(height: isWide ? max(120, geometry.size.height - 125) : min(360, geometry.size.height * 0.48))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                CompactMapToggleChip(
                    title: "Only routes in this area",
                    symbolName: "scope",
                    isOn: visibleAreaFilterBinding
                )

                if let visibleAreaStatusText {
                    Text(visibleAreaStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            .frame(maxWidth: .infinity)

            mapBrowseRouteList
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        }
        .id("map-browse-\(appMeasurementSystemRawValue)")
        .background(TerigoTheme.background.ignoresSafeArea())
        .navigationTitle("Explore")
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
