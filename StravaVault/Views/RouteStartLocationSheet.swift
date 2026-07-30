import CoreLocation
import MapKit
import MapboxMaps
import SwiftUI

struct RouteStartLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue

    let model: RouteLibraryModel

    @State private var requestedRegion: MKCoordinateRegion
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var searchQuery = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var centerOnUserRequestID = 0

    init(model: RouteLibraryModel) {
        self.model = model

        let initialCoordinate = model.selectedStartLocationCoordinate ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let initialRegion = MKCoordinateRegion(
            center: initialCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        )
        _requestedRegion = State(initialValue: initialRegion)
        _visibleRegion = State(initialValue: initialRegion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchSection
                selectedLocationSection
                mapSection

                if model.hasSelectedStartLocation {
                    radiusSection
                }
            }
            .padding(20)
        }
        .id("start-location-\(appMeasurementSystemRawValue)")
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Choose on Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(model.hasSelectedStartLocation ? "Clear" : "Close") {
                    if model.hasSelectedStartLocation {
                        model.clearSelectedStartLocation()
                        if model.usesStartProximitySort {
                            model.clearStartProximitySorts()
                        }
                        searchResults = []
                    } else {
                        dismiss()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search a city, trailhead, or address", text: $searchQuery)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onSubmit {
                        Task { await searchPlaces() }
                    }

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await searchPlaces() }
                } label: {
                    if isSearching {
                        ProgressView()
                    } else {
                        Text("Search")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchQuery.trimmed.isEmpty || isSearching)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if !searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(searchResults.prefix(6)), id: \.self) { item in
                        Button {
                            Task { await select(item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name ?? "Dropped Pin")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)

                                if let subtitle = item.placemark.title {
                                    Text(subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var selectedLocationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Selected Area")

            if model.hasSelectedStartLocation {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedStartLocationDisplayName)
                        .font(.system(.title3, design: .rounded, weight: .bold))

                    if let referenceLine {
                        Text(referenceLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                Text("Search or tap the map to set the center point for a radius filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Map")

            ZStack(alignment: .topTrailing) {
                RouteStartLocationMapView(
                    requestedRegion: $requestedRegion,
                    visibleRegion: $visibleRegion,
                    selectedCoordinate: model.selectedStartLocationCoordinate,
                    radiusMiles: model.selectedStartLocationRadiusMiles,
                    centerOnUserRequestID: centerOnUserRequestID,
                    routeMapStyle: appRouteMapStyle,
                    routeMapPerspective: appRouteMapPerspective,
                    userInterfaceStyle: colorScheme == .dark ? .dark : .light
                ) { coordinate in
                    Task { await selectCoordinate(coordinate, preferredName: nil) }
                }
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                VStack(spacing: 10) {
                    RouteMapSettingsButton()

                    Button {
                        centerOnUserRequestID += 1
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.headline.weight(.bold))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Center on your location")
                }
                .padding(14)
            }
        }
    }

    private var radiusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Radius")

            HStack {
                Text("Distance")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(RouteDisplayFormatter.radius(model.selectedStartLocationRadiusMiles))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { RouteDisplayFormatter.distanceDisplayValue(forMiles: model.selectedStartLocationRadiusMiles) },
                    set: { model.selectedStartLocationRadiusMiles = RouteDisplayFormatter.miles(fromDistanceDisplayValue: $0) }
                ),
                in: RouteDisplayFormatter.distanceDisplayValue(forMiles: 1) ... RouteDisplayFormatter.distanceDisplayValue(forMiles: 150),
                step: RouteDisplayFormatter.distanceSliderStep
            )
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func searchPlaces() async {
        let trimmedQuery = searchQuery.trimmed
        guard !trimmedQuery.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery

        if let coordinate = model.selectedStartLocationCoordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            searchResults = response.mapItems
        } catch {
            searchResults = []
        }
    }

    private func select(_ item: MKMapItem) async {
        let coordinate = item.placemark.coordinate
        let preferredName = item.name ?? item.placemark.title ?? coordinate.formattedLabel
        await selectCoordinate(coordinate, preferredName: preferredName)
    }

    private func selectCoordinate(_ coordinate: CLLocationCoordinate2D, preferredName: String?) async {
        let resolvedDetails = await resolveDetails(for: coordinate, preferredName: preferredName)
        await MainActor.run {
            model.setSelectedStartLocation(
                name: resolvedDetails.referenceName,
                coordinate: coordinate,
                details: resolvedDetails
            )
            model.setStartFilterMode(.radius)

            let region = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22)
            )
            requestedRegion = region
            visibleRegion = region
        }
    }

    private func resolveDetails(for coordinate: CLLocationCoordinate2D, preferredName: String?) async -> RouteStartLocationDetails {
        let fallbackName = preferredName?.trimmed.nilIfEmpty ?? coordinate.formattedLabel
        do {
            let placemarks = try await reverseGeocode(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let placemark = placemarks.first else {
                return RouteStartLocationDetails(
                    referenceName: fallbackName,
                    regionName: "",
                    parkName: "",
                    countyName: "",
                    cityName: fallbackName,
                    stateName: "",
                    countryName: ""
                )
            }

            return placemark.routeStartLocationDetails(preferredName: preferredName, fallbackName: fallbackName)
        } catch {
            return RouteStartLocationDetails(
                referenceName: fallbackName,
                regionName: "",
                parkName: "",
                countyName: "",
                cityName: fallbackName,
                stateName: "",
                countryName: ""
            )
        }
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> [CLPlacemark] {
        let geocoder = CLGeocoder()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLPlacemark], Error>) in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: placemarks ?? [])
                }
            }
        }
    }

    private var referenceLine: String? {
        let orderedValues = [
            model.selectedStartParkName.trimmed.nilIfEmpty,
            model.selectedStartRegionName.trimmed.nilIfEmpty,
            model.selectedStartCountyName.trimmed.nilIfEmpty,
            model.selectedStartCityName.trimmed.nilIfEmpty,
            model.selectedStartStateName.trimmed.nilIfEmpty,
            model.selectedStartCountryName.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }

        var seen = Set<String>()
        let uniqueValues = orderedValues.filter { value in
            seen.insert(value.routeLocationToken).inserted
        }

        return uniqueValues.joined(separator: " • ").nilIfEmpty
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
    }

    private var appRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private var appRouteMapPerspective: AppRouteMapPerspective {
        AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? AppRouteMapPerspective.defaultValue
    }
}

private struct RouteStartLocationMapView: UIViewRepresentable {
    @Binding var requestedRegion: MKCoordinateRegion
    @Binding var visibleRegion: MKCoordinateRegion?
    let selectedCoordinate: CLLocationCoordinate2D?
    let radiusMiles: Double
    let centerOnUserRequestID: Int
    let routeMapStyle: AppRouteMapStyle
    let routeMapPerspective: AppRouteMapPerspective
    let userInterfaceStyle: UIUserInterfaceStyle
    let onSelectCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectCoordinate: onSelectCoordinate)
    }

    func makeUIView(context: Context) -> MapView {
        RouteVaultMapboxConfiguration.configure()

        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                mapStyle: routeMapStyle.resolvedStyle(colorScheme: userInterfaceStyle),
                cameraOptions: CameraOptions(
                    center: requestedRegion.center,
                    zoom: 9,
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
            selectedCoordinate: selectedCoordinate,
            radiusMiles: radiusMiles,
            centerOnUserRequestID: centerOnUserRequestID,
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
        private let onSelectCoordinate: (CLLocationCoordinate2D) -> Void
        private var cancelables = Set<AnyCancelable>()
        private var tapInteractionCancelable: Cancelable?
        private weak var mapView: MapView?
        private var pointManager: PointAnnotationManager?
        private var polygonManager: PolygonAnnotationManager?
        private var visibleRegionBinding: Binding<MKCoordinateRegion?>?
        private var lastRequestedRegionKey: String?
        private var lastCenterOnUserRequestID: Int = -1
        private var lastStyleKey: String?
        private var lastPerspectiveRawValue: String?
        private var currentUsesStandardDarkReadabilityTuning = false

        init(onSelectCoordinate: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onSelectCoordinate = onSelectCoordinate
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
                    usesStandardDarkStyle: self.currentUsesStandardDarkReadabilityTuning
                )
                RouteMapTerrainTuning.apply(
                    to: mapView.mapboxMap,
                    perspective: AppRouteMapPerspective(rawValue: self.lastPerspectiveRawValue ?? AppRouteMapPerspective.defaultValue.rawValue) ?? .defaultValue
                )
                self.recreateManagers(on: mapView)
            }
            .store(in: &cancelables)

            mapView.mapboxMap.onCameraChanged.observe { [weak self, weak mapView] _ in
                guard let self, let mapView else {
                    return
                }

                let bounds = mapView.mapboxMap.coordinateBounds(for: mapView.bounds)
                DispatchQueue.main.async {
                    self.visibleRegionBinding?.wrappedValue = RouteMapboxGeometry.coordinateRegion(for: bounds)
                }
            }
            .store(in: &cancelables)

            tapInteractionCancelable = mapView.mapboxMap.addInteraction(
                TapInteraction { [weak self] interaction in
                    self?.onSelectCoordinate(interaction.coordinate)
                    return true
                }
            )
        }

        func update(
            mapView: MapView,
            requestedRegion: MKCoordinateRegion,
            selectedCoordinate: CLLocationCoordinate2D?,
            radiusMiles: Double,
            centerOnUserRequestID: Int,
            routeMapStyle: AppRouteMapStyle,
            routeMapPerspective: AppRouteMapPerspective,
            userInterfaceStyle: UIUserInterfaceStyle
        ) {
            currentUsesStandardDarkReadabilityTuning = routeMapStyle.usesStandardDarkReadabilityTuning(
                colorScheme: userInterfaceStyle
            )
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: routeMapPerspective
            )
            let styleKey = "\(routeMapStyle.rawValue)-\(userInterfaceStyle.rawValue)"
            if styleKey != lastStyleKey {
                lastStyleKey = styleKey
                mapView.mapboxMap.mapStyle = routeMapStyle.resolvedStyle(colorScheme: userInterfaceStyle)
                recreateManagers(on: mapView)
            }

            ensureManagers(on: mapView)
            updateSelectionAnnotations(
                on: mapView,
                selectedCoordinate: selectedCoordinate,
                radiusMiles: radiusMiles
            )

            let regionKey = [
                requestedRegion.center.latitude,
                requestedRegion.center.longitude,
                requestedRegion.span.latitudeDelta,
                requestedRegion.span.longitudeDelta
            ]
            .map { String(format: "%.6f", $0) }
            .joined(separator: "|")

            let perspectiveDidChange = routeMapPerspective.rawValue != lastPerspectiveRawValue

            if regionKey != lastRequestedRegionKey {
                lastRequestedRegionKey = regionKey
                setRegion(requestedRegion, on: mapView, perspective: routeMapPerspective)
            } else if perspectiveDidChange {
                applyPerspective(routeMapPerspective, on: mapView)
            }

            if centerOnUserRequestID != lastCenterOnUserRequestID {
                lastCenterOnUserRequestID = centerOnUserRequestID
                centerOnUserLocation(on: mapView, perspective: routeMapPerspective)
            }

            lastPerspectiveRawValue = routeMapPerspective.rawValue
        }

        private func recreateManagers(on mapView: MapView) {
            mapView.annotations.removeAnnotationManager(withId: "start-location-pin")
            mapView.annotations.removeAnnotationManager(withId: "start-location-radius")
            pointManager = mapView.annotations.makePointAnnotationManager(id: "start-location-pin")
            polygonManager = mapView.annotations.makePolygonAnnotationManager(id: "start-location-radius")
        }

        private func ensureManagers(on mapView: MapView) {
            if pointManager == nil || polygonManager == nil {
                recreateManagers(on: mapView)
            }
        }

        private func updateSelectionAnnotations(
            on mapView: MapView,
            selectedCoordinate: CLLocationCoordinate2D?,
            radiusMiles: Double
        ) {
            guard let selectedCoordinate else {
                pointManager?.annotations = []
                polygonManager?.annotations = []
                return
            }

            var point = PointAnnotation(coordinate: selectedCoordinate)
            point.image = .init(
                image: UIImage(systemName: "mappin.circle.fill")?.withTintColor(
                    UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 1),
                    renderingMode: .alwaysOriginal
                ) ?? UIImage(),
                name: "start-location-pin-image"
            )
            pointManager?.annotations = [point]

            let polygon = RouteMapboxGeometry.circlePolygon(
                center: selectedCoordinate,
                radiusMeters: radiusMiles * 1_609.34
            )
            var radiusOverlay = PolygonAnnotation(polygon: polygon)
            radiusOverlay.fillColor = StyleColor(UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 0.18))
            radiusOverlay.fillOutlineColor = StyleColor(UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 0.42))
            polygonManager?.annotations = [radiusOverlay]
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
                mapView.camera.ease(to: camera, duration: 0)
            } catch {
                mapView.camera.ease(
                    to: CameraOptions(
                        center: region.center,
                        zoom: 9,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    duration: 0
                )
            }
        }

        private func centerOnUserLocation(
            on mapView: MapView,
            perspective: AppRouteMapPerspective
        ) {
            guard let coordinate = mapView.location.latestLocation?.coordinate else {
                return
            }

            mapView.camera.ease(
                to: CameraOptions(
                    center: coordinate,
                    zoom: 12,
                    pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                ),
                duration: 0.35
            )
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
    }
}
