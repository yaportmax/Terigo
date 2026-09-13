import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MapCenterSearchResult: Identifiable, Hashable {
    let title: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double

    var id: String {
        "\(title.routeLocationToken)-\(subtitle?.routeLocationToken ?? "")-\(latitude)-\(longitude)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init?(_ item: MKMapItem) {
        let title = MapCenterSearchResult.primaryLine(for: item)
        guard let title = title.nilIfEmpty else {
            return nil
        }

        self.title = title
        subtitle = MapCenterSearchResult.subtitle(for: item, excluding: title)
        latitude = item.placemark.coordinate.latitude
        longitude = item.placemark.coordinate.longitude
    }

    private static func primaryLine(for item: MKMapItem) -> String {
        let placemark = item.placemark

        return item.name?.trimmed.nilIfEmpty ??
            placemark.locality?.trimmed.nilIfEmpty ??
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty ??
            placemark.administrativeArea?.trimmed.nilIfEmpty ??
            placemark.country?.trimmed.nilIfEmpty ??
            placemark.title?.trimmed.nilIfEmpty ??
            ""
    }

    private static func subtitle(for item: MKMapItem, excluding primaryLine: String) -> String? {
        let placemark = item.placemark
        let parts = [
            placemark.locality?.trimmed.nilIfEmpty,
            placemark.subAdministrativeArea?.trimmed.nilIfEmpty,
            placemark.administrativeArea?.trimmed.nilIfEmpty,
            placemark.country?.trimmed.nilIfEmpty
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty && $0.routeLocationToken != primaryLine.routeLocationToken }

        guard !parts.isEmpty else {
            return nil
        }

        var seen = Set<String>()
        let deduplicated = parts.filter { value in
            seen.insert(value.routeLocationToken).inserted
        }

        return deduplicated.joined(separator: ", ").nilIfEmpty
    }
}

struct RouteMapCenterSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let searchRegion: MKCoordinateRegion?
    let onSelect: (MapCenterSearchResult) -> Void

    @State private var searchQuery = ""
    @State private var searchResults: [MapCenterSearchResult] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            Group {
                if searchQuery.trimmed.isEmpty {
                    ContentUnavailableView(
                        "Search for a place",
                        systemImage: "magnifyingglass",
                        description: Text("Find a city, park, state, or landmark and center the browse map there.")
                    )
                } else if isSearching && searchResults.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching places...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "map",
                        description: Text("Try a broader place name.")
                    )
                } else {
                    List(searchResults) { result in
                        Button {
                            onSelect(result)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)

                                if let subtitle = result.subtitle {
                                    Text(subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Find Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places")
            .task(id: searchQuery) {
                await refreshSearchResults()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func refreshSearchResults() async {
        let trimmedQuery = searchQuery.trimmed
        guard trimmedQuery.count >= 2 else {
            await MainActor.run {
                isSearching = false
                searchResults = []
            }
            return
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            isSearching = true
        }

        defer {
            Task { @MainActor in
                isSearching = false
            }
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery

        if let searchRegion {
            request.region = searchRegion
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.compactMap(MapCenterSearchResult.init)
            let deduplicatedResults = deduplicated(results)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                searchResults = deduplicatedResults
            }
        } catch {
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                searchResults = []
            }
        }
    }

    private func deduplicated(_ results: [MapCenterSearchResult]) -> [MapCenterSearchResult] {
        var seen = Set<String>()
        var deduplicatedResults: [MapCenterSearchResult] = []

        for result in results {
            let token = "\(result.title.routeLocationToken)-\(result.subtitle?.routeLocationToken ?? "")"
            guard !token.isEmpty, seen.insert(token).inserted else {
                continue
            }

            deduplicatedResults.append(result)
        }

        return deduplicatedResults
    }
}

