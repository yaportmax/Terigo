import CoreLocation
import Foundation
import SwiftData

enum RouteSortDirection: String, CaseIterable, Identifiable {
    case descending
    case ascending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .descending:
            return "Descending"
        case .ascending:
            return "Ascending"
        }
    }

    var shortTitle: String {
        switch self {
        case .descending:
            return "Desc"
        case .ascending:
            return "Asc"
        }
    }

    var symbolName: String {
        switch self {
        case .descending:
            return "arrow.down"
        case .ascending:
            return "arrow.up"
        }
    }
}

enum RouteSortOption: String, CaseIterable, Identifiable {
    case updatedAt
    case name
    case distance
    case climb
    case gradient
    case estimatedTime
    case startProximity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedAt:
            return "Updated"
        case .name:
            return "Name"
        case .distance:
            return "Distance"
        case .climb:
            return "Climb"
        case .gradient:
            return "Gradient"
        case .estimatedTime:
            return "Time"
        case .startProximity:
            return "Closest Start"
        }
    }

    var shortTitle: String {
        switch self {
        case .updatedAt:
            return "Updated"
        case .name:
            return "A-Z"
        case .distance:
            return "Distance"
        case .climb:
            return "Climb"
        case .gradient:
            return "Gradient"
        case .estimatedTime:
            return "Time"
        case .startProximity:
            return "Closest"
        }
    }

    var symbolName: String {
        switch self {
        case .updatedAt:
            return "calendar"
        case .name:
            return "textformat.abc"
        case .distance:
            return "ruler"
        case .climb:
            return "mountain.2"
        case .gradient:
            return "chart.line.uptrend.xyaxis"
        case .estimatedTime:
            return "timer"
        case .startProximity:
            return "location.north.line"
        }
    }

    func directionTitle(for direction: RouteSortDirection) -> String {
        switch self {
        case .startProximity:
            return direction == .descending ? "Closest First" : "Farthest First"
        default:
            return direction.title
        }
    }
}

struct RouteSortCriterion: Identifiable, Equatable {
    let id: UUID
    var option: RouteSortOption
    var direction: RouteSortDirection

    init(
        id: UUID = UUID(),
        option: RouteSortOption,
        direction: RouteSortDirection
    ) {
        self.id = id
        self.option = option
        self.direction = direction
    }

    static let defaultCriterion = RouteSortCriterion(
        option: .updatedAt,
        direction: .descending
    )
}

enum RouteStartFilterMode: String, CaseIterable, Identifiable {
    case none
    case radius
    case namedAreas
    case region
    case park
    case county
    case city
    case state
    case country

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "Reference Only"
        case .radius:
            return "Radius"
        case .namedAreas:
            return "Start Areas"
        case .region:
            return "Region"
        case .park:
            return "Park"
        case .county:
            return "County"
        case .city:
            return "City"
        case .state:
            return "State"
        case .country:
            return "Country"
        }
    }

    var shortTitle: String {
        switch self {
        case .none:
            return "Reference"
        case .radius:
            return "Radius"
        case .namedAreas:
            return "Areas"
        case .region:
            return "Region"
        case .park:
            return "Park"
        case .county:
            return "County"
        case .city:
            return "City"
        case .state:
            return "State"
        case .country:
            return "Country"
        }
    }

    var symbolName: String {
        switch self {
        case .none:
            return "mappin.and.ellipse"
        case .radius:
            return "location.viewfinder"
        case .namedAreas:
            return "map"
        case .region:
            return "map"
        case .park:
            return "tree"
        case .county:
            return "square.3.layers.3d"
        case .city:
            return "building.2"
        case .state:
            return "globe.americas"
        case .country:
            return "globe"
        }
    }

    var tokenTitle: String {
        switch self {
        case .none:
            return "Reference"
        case .radius:
            return "Start Radius"
        case .namedAreas:
            return "Start Areas"
        case .region:
            return "Start Region"
        case .park:
            return "Start Park"
        case .county:
            return "Start County"
        case .city:
            return "Start City"
        case .state:
            return "Start State"
        case .country:
            return "Start Country"
        }
    }

    var supportsInlineNameEntry: Bool {
        switch self {
        case .namedAreas, .region, .park, .county, .city, .state, .country:
            return true
        case .none, .radius:
            return false
        }
    }

    static var inlineNameModes: [RouteStartFilterMode] {
        [.namedAreas]
    }
}

struct RouteStartLocationDetails: Equatable {
    var referenceName: String
    var regionName: String
    var parkName: String
    var countyName: String
    var cityName: String
    var stateName: String
    var countryName: String

    func value(for mode: RouteStartFilterMode) -> String? {
        switch mode {
        case .none, .radius, .namedAreas:
            return nil
        case .region:
            return regionName.trimmed.nilIfEmpty
        case .park:
            return parkName.trimmed.nilIfEmpty
        case .county:
            return countyName.trimmed.nilIfEmpty
        case .city:
            return cityName.trimmed.nilIfEmpty
        case .state:
            return stateName.trimmed.nilIfEmpty
        case .country:
            return countryName.trimmed.nilIfEmpty
        }
    }

    var availableFilterModes: [RouteStartFilterMode] {
        var modes: [RouteStartFilterMode] = [.none, .radius]

        if [regionName, parkName, countyName, cityName, stateName, countryName]
            .contains(where: { $0.trimmed.nilIfEmpty != nil }) {
            modes.append(.namedAreas)
        }

        for mode in [RouteStartFilterMode.region, .park, .county, .city, .state, .country] {
            if value(for: mode) != nil {
                modes.append(mode)
            }
        }

        return modes
    }

    init(
        referenceName: String,
        regionName: String,
        parkName: String,
        countyName: String,
        cityName: String,
        stateName: String,
        countryName: String
    ) {
        self.referenceName = referenceName
        self.regionName = regionName
        self.parkName = parkName
        self.countyName = countyName
        self.cityName = cityName
        self.stateName = stateName
        self.countryName = countryName
    }
}

enum RouteMovementFilter: String, CaseIterable, Identifiable {
    case all
    case onBike
    case onFoot
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Any Movement"
        case .onBike:
            return "On Bike"
        case .onFoot:
            return "On Foot"
        case .other:
            return "Other"
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "Any"
        case .onBike:
            return "Bike"
        case .onFoot:
            return "Foot"
        case .other:
            return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .all:
            return "figure.mixed.cardio"
        case .onBike:
            return "figure.outdoor.cycle"
        case .onFoot:
            return "figure.walk"
        case .other:
            return "sparkles"
        }
    }

    func matches(_ route: RouteRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .onBike:
            return route.movementKind == .onBike
        case .onFoot:
            return route.movementKind == .onFoot
        case .other:
            return route.movementKind == .other
        }
    }
}

enum RouteSportKind: String, CaseIterable, Identifiable {
    case ride
    case mountainBike
    case mixedRide
    case gravelRide
    case cyclocross
    case run
    case trailRun
    case walk
    case hike
    case snowshoe
    case ski
    case wheelchair
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ride:
            return "Road Ride"
        case .mountainBike:
            return "Mountain Bike"
        case .mixedRide:
            return "Mixed Ride"
        case .gravelRide:
            return "Gravel Ride"
        case .cyclocross:
            return "Cyclocross"
        case .run:
            return "Run"
        case .trailRun:
            return "Trail Run"
        case .walk:
            return "Walk"
        case .hike:
            return "Hike"
        case .snowshoe:
            return "Snowshoe"
        case .ski:
            return "Ski"
        case .wheelchair:
            return "Wheelchair"
        case .other:
            return "Other"
        }
    }

    var shortTitle: String {
        switch self {
        case .ride:
            return "Road"
        case .mountainBike:
            return "MTB"
        case .mixedRide:
            return "Mixed"
        case .gravelRide:
            return "Gravel"
        case .cyclocross:
            return "Cross"
        case .run:
            return "Run"
        case .trailRun:
            return "Trail Run"
        case .walk:
            return "Walk"
        case .hike:
            return "Hike"
        case .snowshoe:
            return "Snowshoe"
        case .ski:
            return "Ski"
        case .wheelchair:
            return "Wheelchair"
        case .other:
            return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .ride:
            return "activity-ride"
        case .mountainBike:
            return "activity-mountain-bike"
        case .mixedRide:
            return "activity-mixed-ride"
        case .gravelRide:
            return "activity-gravel-ride"
        case .cyclocross:
            return "activity-cyclocross"
        case .run:
            return "activity-run"
        case .trailRun:
            return "activity-trail-run"
        case .walk:
            return "activity-walk"
        case .hike:
            return "activity-hike"
        case .snowshoe:
            return "activity-snowshoe"
        case .ski:
            return "activity-ski"
        case .wheelchair:
            return "activity-wheelchair"
        case .other:
            return "activity-other"
        }
    }

    var movementKind: RouteMovementFilter {
        switch self {
        case .ride, .mountainBike, .mixedRide, .gravelRide, .cyclocross:
            return .onBike
        case .run, .trailRun, .walk, .hike, .snowshoe:
            return .onFoot
        case .ski, .wheelchair, .other:
            return .other
        }
    }
}

enum RouteClimbFilter: String, CaseIterable, Identifiable {
    case all
    case flat
    case rolling
    case mountainous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Any Climb"
        case .flat:
            return "Flat"
        case .rolling:
            return "Rolling"
        case .mountainous:
            return "Big Climb"
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "Any"
        case .flat:
            return "Flat"
        case .rolling:
            return "Rolling"
        case .mountainous:
            return "Big Climb"
        }
    }

    var symbolName: String {
        "mountain.2"
    }

    func matches(_ route: RouteRecord) -> Bool {
        let climbFeet = route.elevationGainMeters * 3.28084

        switch self {
        case .all:
            return true
        case .flat:
            return climbFeet < 500
        case .rolling:
            return climbFeet >= 500 && climbFeet < 2_000
        case .mountainous:
            return climbFeet >= 2_000
        }
    }
}

enum RouteSurfaceFilter: String, CaseIterable, Identifiable {
    case all
    case paved
    case trail
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Any Surface"
        case .paved:
            return "Paved"
        case .trail:
            return "Trail"
        case .mixed:
            return "Mixed"
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "Any"
        case .paved:
            return "Paved"
        case .trail:
            return "Trail"
        case .mixed:
            return "Mixed"
        }
    }

    var symbolName: String {
        "point.bottomleft.forward.to.point.topright.scurvepath"
    }

    func matches(_ route: RouteRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .paved:
            return route.surfaceKind == .paved
        case .trail:
            return route.surfaceKind == .trail
        case .mixed:
            return route.surfaceKind == .mixed
        }
    }
}

enum RouteSportFilter: String, CaseIterable, Identifiable {
    case all
    case ride
    case mountainBike
    case mixedRide
    case gravelRide
    case cyclocross
    case run
    case trailRun
    case walk
    case hike
    case snowshoe
    case ski
    case wheelchair
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Sports"
        case .ride:
            return RouteSportKind.ride.title
        case .mountainBike:
            return RouteSportKind.mountainBike.title
        case .mixedRide:
            return RouteSportKind.mixedRide.title
        case .gravelRide:
            return RouteSportKind.gravelRide.title
        case .cyclocross:
            return RouteSportKind.cyclocross.title
        case .run:
            return RouteSportKind.run.title
        case .trailRun:
            return RouteSportKind.trailRun.title
        case .walk:
            return RouteSportKind.walk.title
        case .hike:
            return RouteSportKind.hike.title
        case .snowshoe:
            return RouteSportKind.snowshoe.title
        case .ski:
            return RouteSportKind.ski.title
        case .wheelchair:
            return RouteSportKind.wheelchair.title
        case .other:
            return RouteSportKind.other.title
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "Any"
        case .ride:
            return RouteSportKind.ride.shortTitle
        case .mountainBike:
            return RouteSportKind.mountainBike.shortTitle
        case .mixedRide:
            return RouteSportKind.mixedRide.shortTitle
        case .gravelRide:
            return RouteSportKind.gravelRide.shortTitle
        case .cyclocross:
            return RouteSportKind.cyclocross.shortTitle
        case .run:
            return RouteSportKind.run.shortTitle
        case .trailRun:
            return RouteSportKind.trailRun.shortTitle
        case .walk:
            return RouteSportKind.walk.shortTitle
        case .hike:
            return RouteSportKind.hike.shortTitle
        case .snowshoe:
            return RouteSportKind.snowshoe.shortTitle
        case .ski:
            return RouteSportKind.ski.shortTitle
        case .wheelchair:
            return RouteSportKind.wheelchair.shortTitle
        case .other:
            return RouteSportKind.other.shortTitle
        }
    }

    var symbolName: String {
        switch self {
        case .all:
            return "activity-all-sports"
        case .ride:
            return RouteSportKind.ride.symbolName
        case .mountainBike:
            return RouteSportKind.mountainBike.symbolName
        case .mixedRide:
            return RouteSportKind.mixedRide.symbolName
        case .gravelRide:
            return RouteSportKind.gravelRide.symbolName
        case .cyclocross:
            return RouteSportKind.cyclocross.symbolName
        case .run:
            return RouteSportKind.run.symbolName
        case .trailRun:
            return RouteSportKind.trailRun.symbolName
        case .walk:
            return RouteSportKind.walk.symbolName
        case .hike:
            return RouteSportKind.hike.symbolName
        case .snowshoe:
            return RouteSportKind.snowshoe.symbolName
        case .ski:
            return RouteSportKind.ski.symbolName
        case .wheelchair:
            return RouteSportKind.wheelchair.symbolName
        case .other:
            return RouteSportKind.other.symbolName
        }
    }

    var movementKind: RouteMovementFilter {
        switch self {
        case .all:
            return .all
        case .ride, .mountainBike, .mixedRide, .gravelRide, .cyclocross:
            return .onBike
        case .run, .trailRun, .walk, .hike, .snowshoe:
            return .onFoot
        case .ski, .wheelchair, .other:
            return .other
        }
    }

    func isAvailable(for movement: RouteMovementFilter) -> Bool {
        movement == .all || self == .all || movementKind == movement
    }

    func matches(_ route: RouteRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .ride:
            return route.sportKind == .ride
        case .mountainBike:
            return route.sportKind == .mountainBike
        case .mixedRide:
            return route.sportKind == .mixedRide
        case .gravelRide:
            return route.sportKind == .gravelRide
        case .cyclocross:
            return route.sportKind == .cyclocross
        case .run:
            return route.sportKind == .run
        case .trailRun:
            return route.sportKind == .trailRun
        case .walk:
            return route.sportKind == .walk
        case .hike:
            return route.sportKind == .hike
        case .snowshoe:
            return route.sportKind == .snowshoe
        case .ski:
            return route.sportKind == .ski
        case .wheelchair:
            return route.sportKind == .wheelchair
        case .other:
            return route.sportKind == .other
        }
    }

    init(sportKind: RouteSportKind) {
        switch sportKind {
        case .ride:
            self = .ride
        case .mountainBike:
            self = .mountainBike
        case .mixedRide:
            self = .mixedRide
        case .gravelRide:
            self = .gravelRide
        case .cyclocross:
            self = .cyclocross
        case .run:
            self = .run
        case .trailRun:
            self = .trailRun
        case .walk:
            self = .walk
        case .hike:
            self = .hike
        case .snowshoe:
            self = .snowshoe
        case .ski:
            self = .ski
        case .wheelchair:
            self = .wheelchair
        case .other:
            self = .other
        }
    }
}

enum RouteDistanceFilter: String, CaseIterable, Identifiable {
    case all
    case short
    case medium
    case long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Any Distance"
        case .short:
            return "< 20 mi"
        case .medium:
            return "20-50 mi"
        case .long:
            return "50+ mi"
        }
    }

    var shortTitle: String {
        switch self {
        case .all:
            return "Any"
        case .short:
            return "<20 mi"
        case .medium:
            return "20-50 mi"
        case .long:
            return "50+ mi"
        }
    }

    var symbolName: String {
        "ruler"
    }

    func matches(_ route: RouteRecord) -> Bool {
        let miles = route.distanceMeters * 0.000621371
        switch self {
        case .all:
            return true
        case .short:
            return miles < 20
        case .medium:
            return miles >= 20 && miles < 50
        case .long:
            return miles >= 50
        }
    }
}

@Model
final class RouteStartHub {
    @Attribute(.unique) var uuid: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var regionName: String?
    var parkName: String?
    var countyName: String?
    var cityName: String?
    var stateName: String?
    var countryName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        latitude: Double,
        longitude: Double,
        details: RouteStartLocationDetails
    ) {
        uuid = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        regionName = details.regionName.trimmed.nilIfEmpty
        parkName = details.parkName.trimmed.nilIfEmpty
        countyName = details.countyName.trimmed.nilIfEmpty
        cityName = details.cityName.trimmed.nilIfEmpty
        stateName = details.stateName.trimmed.nilIfEmpty
        countryName = details.countryName.trimmed.nilIfEmpty
        createdAt = .now
        updatedAt = .now
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var details: RouteStartLocationDetails {
        RouteStartLocationDetails(
            referenceName: name,
            regionName: regionName ?? "",
            parkName: parkName ?? "",
            countyName: countyName ?? "",
            cityName: cityName ?? "",
            stateName: stateName ?? "",
            countryName: countryName ?? ""
        )
    }

    func update(name: String, details: RouteStartLocationDetails, coordinate: CLLocationCoordinate2D) {
        self.name = name
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        regionName = details.regionName.trimmed.nilIfEmpty
        parkName = details.parkName.trimmed.nilIfEmpty
        countyName = details.countyName.trimmed.nilIfEmpty
        cityName = details.cityName.trimmed.nilIfEmpty
        stateName = details.stateName.trimmed.nilIfEmpty
        countryName = details.countryName.trimmed.nilIfEmpty
        updatedAt = .now
    }
}

struct DashboardMetric: Identifiable {
    let id: String
    let title: String
    let value: String
    let caption: String
}

@Model
final class RouteList {
    @Attribute(.unique) var id: String
    var name: String
    var listDescription: String
    var isPublic: Bool
    var shareCode: String
    var sharingVisibilityRawValue: String = RouteListVisibilityMode.privateAccess.rawValue
    var collaborationModeRawValue: String = RouteListCollaborationMode.ownerOnly.rawValue
    var remoteListID: String?
    var remoteOwnerAccountID: String?
    var remoteOwnerDisplayName: String?
    var remoteShareToken: String?
    var remoteAccessRoleRawValue: String?
    var remoteRevision: Int = 0
    var lastRemoteSyncAt: Date?
    var lastRemoteSyncFingerprint: String?
    var collaboratorEmailsBlob: String?
    var viewerEmailsBlob: String?
    var preferredDensityRawValue: String?
    var createdAt: Date
    var updatedAt: Date
    var importedRouteReferencesBlob: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        listDescription: String = "",
        isPublic: Bool = false,
        shareCode: String = RouteList.makeShareCode(),
        sharingVisibility: RouteListVisibilityMode? = nil,
        collaborationMode: RouteListCollaborationMode = .ownerOnly,
        remoteListID: String? = nil,
        remoteOwnerAccountID: String? = nil,
        remoteOwnerDisplayName: String? = nil,
        remoteShareToken: String? = nil,
        remoteAccessRole: RouteVaultRemoteListAccessRole? = nil,
        remoteRevision: Int = 0,
        lastRemoteSyncAt: Date? = nil,
        lastRemoteSyncFingerprint: String? = nil,
        collaboratorCodes: [String] = [],
        viewerCodes: [String] = [],
        preferredDensityRawValue: String? = AppRouteListDensity.defaultValue.rawValue,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        importedRouteReferences: [RouteListSharedRouteReference] = []
    ) {
        self.id = id
        self.name = name.trimmed
        self.listDescription = listDescription
        self.isPublic = isPublic
        self.shareCode = shareCode
        sharingVisibilityRawValue = (sharingVisibility ?? (isPublic ? .linkView : .privateAccess)).rawValue
        collaborationModeRawValue = collaborationMode.rawValue
        self.remoteListID = remoteListID
        self.remoteOwnerAccountID = remoteOwnerAccountID
        self.remoteOwnerDisplayName = remoteOwnerDisplayName
        self.remoteShareToken = remoteShareToken
        remoteAccessRoleRawValue = remoteAccessRole?.rawValue
        self.remoteRevision = remoteRevision
        self.lastRemoteSyncAt = lastRemoteSyncAt
        self.lastRemoteSyncFingerprint = lastRemoteSyncFingerprint
        collaboratorEmailsBlob = collaboratorCodes
            .compactMap(RouteVaultAccountCode.normalize)
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        viewerEmailsBlob = viewerCodes
            .compactMap(RouteVaultAccountCode.normalize)
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        self.preferredDensityRawValue = preferredDensityRawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        importedRouteReferencesBlob = RouteListShareCodec.encode(importedRouteReferences)
    }

    var importedRouteReferences: [RouteListSharedRouteReference] {
        get { RouteListShareCodec.decode(importedRouteReferencesBlob) }
        set { importedRouteReferencesBlob = RouteListShareCodec.encode(newValue) }
    }

    var normalizedName: String {
        name.routeLabelIdentifier
    }

    var hasDescription: Bool {
        listDescription.trimmed.nilIfEmpty != nil
    }

    var sharingVisibility: RouteListVisibilityMode {
        get {
            RouteListVisibilityMode(rawValue: sharingVisibilityRawValue) ?? (isPublic ? .linkView : .privateAccess)
        }
        set {
            sharingVisibilityRawValue = newValue.rawValue
            isPublic = newValue != .privateAccess
        }
    }

    var collaborationMode: RouteListCollaborationMode {
        get { RouteListCollaborationMode(rawValue: collaborationModeRawValue) ?? .ownerOnly }
        set { collaborationModeRawValue = newValue.rawValue }
    }

    var collaboratorCodes: [String] {
        get {
            collaboratorEmailsBlob?
                .split(separator: ",")
                .map { RouteVaultAccountCode.normalize(String($0)) }
                .compactMap { $0 } ?? []
        }
        set {
            collaboratorEmailsBlob = newValue
                .compactMap(RouteVaultAccountCode.normalize)
                .filter { !$0.isEmpty }
                .joined(separator: ",")
        }
    }

    var viewerCodes: [String] {
        get {
            viewerEmailsBlob?
                .split(separator: ",")
                .map { RouteVaultAccountCode.normalize(String($0)) }
                .compactMap { $0 } ?? []
        }
        set {
            viewerEmailsBlob = newValue
                .compactMap(RouteVaultAccountCode.normalize)
                .filter { !$0.isEmpty }
                .joined(separator: ",")
        }
    }

    var hasRemoteSyncIdentity: Bool {
        remoteListID?.trimmed.nilIfEmpty != nil
    }

    var remoteAccessRole: RouteVaultRemoteListAccessRole? {
        get {
            guard let rawValue = remoteAccessRoleRawValue?.trimmed.nilIfEmpty else {
                return nil
            }

            return RouteVaultRemoteListAccessRole(rawValue: rawValue)
        }
        set {
            remoteAccessRoleRawValue = newValue?.rawValue
        }
    }

    var isFollowedSharedList: Bool {
        guard let remoteAccessRole else {
            return false
        }

        return !remoteAccessRole.isOwnedByCurrentAccount
    }

    var canSyncRemotelyFromThisDevice: Bool {
        guard let remoteAccessRole else {
            return true
        }

        return remoteAccessRole.canEdit
    }

    var canGenerateRemoteShareLink: Bool {
        !isFollowedSharedList &&
        sharingVisibility != .privateAccess &&
        remoteShareToken?.trimmed.nilIfEmpty != nil
    }

    var preferredDensity: AppRouteListDensity {
        get { AppRouteListDensity(rawValue: preferredDensityRawValue ?? "") ?? .defaultValue }
        set { preferredDensityRawValue = newValue.rawValue }
    }

    func touch() {
        updatedAt = .now
    }

    static func makeShareCode() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
            .uppercased()
    }
}

enum RouteListVisibilityMode: String, CaseIterable, Codable {
    case privateAccess = "private"
    case invitedView = "invited_viewers"
    case linkView = "link_view"

    var title: String {
        switch self {
        case .privateAccess:
            return "Private"
        case .invitedView:
            return "Specific Accounts Can View"
        case .linkView:
            return "Anyone With Link Can View"
        }
    }

    var description: String {
        switch self {
        case .privateAccess:
            return "Only you can open this list."
        case .invitedView:
            return "Only invited Terigo accounts can open this list."
        case .linkView:
            return "Anyone with the share link can view the live list."
        }
    }
}

enum RouteListCollaborationMode: String, CaseIterable, Codable {
    case ownerOnly = "owner_only"
    case linkEditors = "link_editors"
    case invitedEditors = "invited_editors"

    var title: String {
        switch self {
        case .ownerOnly:
            return "Only You Can Edit"
        case .linkEditors:
            return "Anyone With Link Can Edit"
        case .invitedEditors:
            return "Specific Accounts Can Edit"
        }
    }

    var description: String {
        switch self {
        case .ownerOnly:
            return "Shared viewers cannot change the list."
        case .linkEditors:
            return "Anyone with the link can collaborate."
        case .invitedEditors:
            return "Only invited Terigo accounts can edit."
        }
    }
}

struct RouteListSharedRouteReference: Codable, Hashable, Identifiable {
    let routeID: Int
    let name: String

    var id: Int { routeID }
}

struct RouteListSharePayload: Codable, Equatable {
    let version: Int
    let name: String
    let listDescription: String
    let isPublic: Bool
    let shareCode: String
    let routes: [RouteListSharedRouteReference]

    init(
        version: Int = 1,
        name: String,
        listDescription: String,
        isPublic: Bool,
        shareCode: String,
        routes: [RouteListSharedRouteReference]
    ) {
        self.version = version
        self.name = name
        self.listDescription = listDescription
        self.isPublic = isPublic
        self.shareCode = shareCode
        self.routes = routes
    }

    func shareURL() -> URL? {
        guard let payload = RouteListShareCodec.encode(self) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "routevault"
        components.host = "lists"
        components.path = "/import"
        components.queryItems = [
            URLQueryItem(name: "payload", value: payload)
        ]
        return components.url
    }

    static func decode(from url: URL) -> RouteListSharePayload? {
        guard url.scheme?.lowercased() == "routevault",
              url.host?.lowercased() == "lists" else {
            return nil
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard path == "import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payload = components.queryItems?.first(where: { $0.name == "payload" })?.value else {
            return nil
        }

        return RouteListShareCodec.decode(payload)
    }
}

private enum RouteListShareCodec {
    static func encode(_ payload: RouteListSharePayload) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }

        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ payload: String?) -> RouteListSharePayload? {
        guard let data = decodeData(payload) else {
            return nil
        }

        return try? JSONDecoder().decode(RouteListSharePayload.self, from: data)
    }

    static func encode(_ references: [RouteListSharedRouteReference]) -> String? {
        guard !references.isEmpty,
              let data = try? JSONEncoder().encode(references) else {
            return nil
        }

        return data.base64EncodedString()
    }

    static func decode(_ blob: String?) -> [RouteListSharedRouteReference] {
        guard let blob,
              let data = Data(base64Encoded: blob),
              let references = try? JSONDecoder().decode([RouteListSharedRouteReference].self, from: data) else {
            return []
        }

        return references
    }

    private static func decodeData(_ payload: String?) -> Data? {
        guard let payload = payload?.trimmed.nilIfEmpty else {
            return nil
        }

        let paddingLength = (4 - (payload.count % 4)) % 4
        let normalizedPayload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: paddingLength)

        return Data(base64Encoded: normalizedPayload)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }

    var routeLocationToken: String {
        trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }

    var routeLabelIdentifier: String {
        trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
    }
}
