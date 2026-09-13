import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum RouteSpotlightIdentifier {
    private static let routePrefix = "route:"

    case route(Int)

    static func routeIdentifier(for route: RouteRecord) -> String {
        "\(routePrefix)\(route.stravaRouteID)"
    }

    static func parse(_ identifier: String) -> RouteSpotlightIdentifier? {
        if identifier.hasPrefix(routePrefix),
           let routeID = Int(identifier.dropFirst(routePrefix.count)) {
            return .route(routeID)
        }

        return nil
    }
}

enum RouteSpotlightIndexer {
    static func reindex(routes: [RouteRecord]) async {
        let searchableIndex = CSSearchableIndex.default()

        do {
            try await delete(domainIdentifiers: ["com.myaport.RouteVault.routeLibrary"], from: searchableIndex)
            let items = searchableItems(routes: routes)
            guard !items.isEmpty else {
                return
            }

            try await add(items: items, to: searchableIndex)
        } catch {
            // Search indexing should not block the route library experience.
        }
    }

    private static func searchableItems(routes: [RouteRecord]) -> [CSSearchableItem] {
        routes.map { route -> CSSearchableItem in
            let attributeSet = CSSearchableItemAttributeSet(contentType: .item)
            attributeSet.title = route.name
            attributeSet.contentDescription = [
                route.displayLocation.nilIfEmpty,
                route.sportDisplayName,
                RouteDisplayFormatter.distance(route.distanceMeters),
                RouteDisplayFormatter.climb(route.elevationGainMeters),
                route.notes.trimmed.nilIfEmpty
            ]
            .compactMap { $0 }
            .joined(separator: " • ")
            attributeSet.keywords = route.searchKeywords
            return CSSearchableItem(
                uniqueIdentifier: RouteSpotlightIdentifier.routeIdentifier(for: route),
                domainIdentifier: "com.myaport.RouteVault.routeLibrary",
                attributeSet: attributeSet
            )
        }
    }

    private static func add(items: [CSSearchableItem], to index: CSSearchableIndex) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func delete(domainIdentifiers: [String], from index: CSSearchableIndex) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

