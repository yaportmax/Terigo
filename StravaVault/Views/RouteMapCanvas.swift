import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum RouteMapMarkerZoomStyle {
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

struct MapOverlayIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct CompactMapToggleChip: View {
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

struct RouteMapBrowseCanvas<Controls: View>: View {
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
            if RouteVaultMapboxConfiguration.isConfigured {
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
            } else {
                TerigoNativeMap(
                    tracks: selectedRoute.map { [$0.routeCoordinates] } ?? [],
                    markers: markerGroups.map { group in
                        TerigoNativeMap.Marker(id: group.id, title: group.routes.count == 1 ? group.routes[0].name : "\(group.routes.count) routes", coordinate: group.coordinate)
                    },
                    requestedRegion: requestedRegion ?? fallbackRegion,
                    centerRequest: centerOnUserRequestID,
                    fitRequest: fitRequestID,
                    onRegionChange: { region in
                        visibleRegion = region
                        onCameraRegionChanged(region)
                    },
                    onSelectMarker: { id in
                        if let group = markerGroups.first(where: { $0.id == id }) { onSelectMarkerGroup(group) }
                    }
                )
            }


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


/// Apple Maps keeps unconfigured and local-only builds useful without a Mapbox token.
/// Configured builds retain the Mapbox terrain and offline-tile implementations.
struct TerigoNativeMap: View {
    struct Marker: Identifiable {
        let id: String
        let title: String
        let coordinate: CLLocationCoordinate2D
    }
    let tracks: [[CLLocationCoordinate2D]]
    var markers: [Marker] = []
    var requestedRegion: MKCoordinateRegion? = nil
    var centerRequest: Int = 0
    var fitRequest: Int = 0
    var followCoordinate: CLLocationCoordinate2D? = nil
    var onRegionChange: (MKCoordinateRegion) -> Void = { _ in }
    var onSelectMarker: (String) -> Void = { _ in }
    var onUserInteraction: () -> Void = {}
    @AppStorage(AppRouteMapStyle.storageKey) private var styleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(tracks.indices, id: \.self) { index in
                MapPolyline(coordinates: tracks[index])
                    .stroke(TerigoTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(markers) { marker in
                Annotation(marker.title, coordinate: marker.coordinate) {
                    Button { onSelectMarker(marker.id) } label: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.white)
                            .background(TerigoTheme.accent, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    .accessibilityLabel(marker.title)
                }
            }
            UserAnnotation()
        }
        .mapStyle(mapStyle)
        .onAppear { if let requestedRegion { position = .region(requestedRegion) } }
        .onChange(of: regionKey) { _, _ in
            if let requestedRegion { position = .region(requestedRegion) }
        }
        .onChange(of: centerRequest) { _, _ in position = .userLocation(fallback: .automatic) }
        .onChange(of: fitRequest) { _, _ in position = .automatic }
        .onChange(of: followCoordinate?.latitude) { _, _ in followLocation() }
        .onChange(of: followCoordinate?.longitude) { _, _ in followLocation() }
        .onMapCameraChange(frequency: .onEnd) { context in
            onRegionChange(context.region)
            if position.positionedByUser { onUserInteraction() }
        }
    }

    private var mapStyle: MapKit.MapStyle {
        switch AppRouteMapStyle.resolved(from: styleRawValue) {
        case .satellite: return .imagery(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic)
        default: return .standard(elevation: .realistic, pointsOfInterest: .excludingAll)
        }
    }
    private var regionKey: String {
        guard let region = requestedRegion else { return "automatic" }
        return "\(region.center.latitude)-\(region.center.longitude)-\(region.span.latitudeDelta)-\(region.span.longitudeDelta)"
    }
    private func followLocation() {
        if let followCoordinate {
            position = .region(MKCoordinateRegion(center: followCoordinate, latitudinalMeters: 1400, longitudinalMeters: 1400))
        }
    }
}
