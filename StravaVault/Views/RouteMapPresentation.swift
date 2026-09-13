import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteMapBrowseFullScreenView: View {
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

struct RouteStartMarkerGroup: Identifiable {
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


struct RouteMapSelectedGroupCarousel: View {
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

extension MKCoordinateRegion {
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latitudeMin = center.latitude - (span.latitudeDelta / 2)
        let latitudeMax = center.latitude + (span.latitudeDelta / 2)
        let longitudeDistance = abs((coordinate.longitude - center.longitude + 540).truncatingRemainder(dividingBy: 360) - 180)

        return coordinate.latitude >= latitudeMin &&
            coordinate.latitude <= latitudeMax &&
            longitudeDistance <= span.longitudeDelta / 2
    }
}

struct RouteMapBrowseRow: View {
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
