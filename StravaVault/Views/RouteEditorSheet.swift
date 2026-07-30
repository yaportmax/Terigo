import Charts
import MapKit
import MapboxMaps
import Network
import SwiftData
import SwiftUI
import UIKit

private enum RouteEditorBannerTone {
    case success
    case error
}

struct RouteEditorSheet: View {
    private enum ScreenshotAnchor: String {
        case overviewSection
        case weatherSection
    }

    private actor ElevationBackfillCoordinator {
        private var retryAfterByRouteID: [Int: Date] = [:]

        func retryAfter(for routeID: Int) -> Date? {
            guard let retryAfter = retryAfterByRouteID[routeID] else {
                return nil
            }

            if retryAfter <= Date() {
                retryAfterByRouteID[routeID] = nil
                return nil
            }

            return retryAfter
        }

        func setRetryAfter(_ retryAfter: Date?, for routeID: Int) {
            guard let retryAfter else {
                retryAfterByRouteID[routeID] = Date().addingTimeInterval(5 * 60)
                return
            }

            retryAfterByRouteID[routeID] = retryAfter
        }

        func clearRetryAfter(for routeID: Int) {
            retryAfterByRouteID[routeID] = nil
        }
    }

    private struct BannerMessage: Identifiable {
        let id = UUID()
        let text: String
        let tone: RouteEditorBannerTone
    }

    private enum RouteActionError: LocalizedError {
        case notConnected
        case privateRouteRequiresReadAll

        var errorDescription: String? {
            switch self {
        case .notConnected:
            return "Connect Strava before downloading route files from the service."
            case .privateRouteRequiresReadAll:
                return "Private route GPX export requires Strava `read_all` access. Reconnect Strava and grant full route access."
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(RouteTrackingActivityStore.activeRouteIDDefaultsKey) private var activeRouteTrackingRouteID = 0
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @Query(sort: [SortDescriptor(\RouteList.name)]) private var allLists: [RouteList]

    @Bindable var route: RouteRecord

    @State private var isDownloadingOffline = false
    @State private var isRefreshingRoute = false
    @State private var isShowingFullScreenMap = false
    @State private var isShowingDownloadOptions = false
    @State private var isShowingNewListPrompt = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingStartActivityWarning = false
    @State private var bannerMessage: BannerMessage?
    @State private var newListDraft = ""
    @State private var activeElevationDistanceMeters: Double?
    @State private var lockedElevationDistanceMeters: Double?
    @State private var isShowingElevationChart = true
    @State private var isLoadingElevationProfile = false
    @State private var elevationProfileStatusMessage: String?
    @State private var weatherSnapshot: RouteWeatherSnapshot?
    @State private var weatherStatusMessage: String?
    @State private var isLoadingWeather = false
    @State private var offlineDownloadProgress: RouteOfflineDownloadProgress?
    @State private var offlineStatusRevision = 0
    @State private var offlineDownloadSelection = RouteOfflineDownloadSelection(
        includesGPX: true,
        mapStyles: [AppRouteMapStyle.defaultValue],
        includesTerrain: false
    )
    @State private var didApplyScreenshotPresentation = false

    private let apiService = StravaAPIService()
    private let credentialStore = StravaCredentialStore()
    private let gpxImportService = GPXImportService()
    private let offlineAssetService = RouteOfflineAssetService()
    private let routeDetailDownloadCoordinator = RouteDetailDownloadCoordinator()
    private let weatherService = RouteWeatherService.shared
    private let elevationBackfillCoordinator = ElevationBackfillCoordinator()
    var onDelete: (RouteRecord) -> Void = { _ in }

    private var offlineStatus: RouteOfflineAssetStatus {
        offlineAssetService.offlineStatus(for: route)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                bannerSection
                mapSection
                actionsSection
                overviewSection
                    .id(ScreenshotAnchor.overviewSection.rawValue)
                weatherSection
                    .id(ScreenshotAnchor.weatherSection.rawValue)
                organizationSection
                notesSection
                deleteSection
            }
            .accessibilityIdentifier("route-editor-screen-\(route.stravaRouteID)")
            .navigationTitle(route.name.trimmed.nilIfEmpty ?? "Route Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: saveAndDismiss)
                        .fontWeight(.semibold)
                }
            }
            .alert("New List", isPresented: $isShowingNewListPrompt) {
                TextField("List name", text: $newListDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { }
                Button("Add", action: addNewList)
                    .disabled(newListDraft.trimmed.isEmpty)
            } message: {
                Text("Lists can be renamed, described, and shared later from Manage Lists.")
            }
            .confirmationDialog(
                "Delete Route?",
                isPresented: $isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Route", role: .destructive, action: deleteRoute)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .alert(
                "Start Without Elevation Profile?",
                isPresented: $isShowingStartActivityWarning
            ) {
                Button("Cancel", role: .cancel) { }
                if canDownloadMissingElevationProfile {
                    Button("Download Route Data") {
                        presentDownloadOptions()
                    }
                }
                Button("Start Anyway") {
                    beginActivityTracking()
                }
            } message: {
                Text(startActivityWarningMessage)
            }
            .fullScreenCover(isPresented: $isShowingFullScreenMap) {
                RouteFullScreenMapView(
                    route: route,
                    activeElevationDistanceMeters: $activeElevationDistanceMeters,
                    lockedElevationDistanceMeters: $lockedElevationDistanceMeters,
                    isShowingElevationChart: isShowingElevationChart,
                    isLoadingElevationProfile: isLoadingElevationProfile,
                    elevationProfileStatusMessage: resolvedElevationProfileStatusMessage,
                    routeDetailsActionTitle: detailDownloadButtonTitle,
                    canDownloadRouteDetails: canDownloadRouteDetails,
                    onDownloadRouteDetails: {
                        presentDownloadOptions()
                    },
                    onToggleElevationChart: toggleElevationChartVisibility
                )
            }
            .sheet(isPresented: $isShowingDownloadOptions) {
                NavigationStack {
                    RouteOfflineDownloadSheet(
                        route: route,
                        offlineStatus: offlineStatus,
                        selection: $offlineDownloadSelection,
                        isDownloading: isDownloadingOffline,
                        downloadProgress: offlineDownloadProgress,
                        onDownload: {
                            Task { await downloadOfflineBundle(using: offlineDownloadSelection) }
                        }
                    )
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                applyScreenshotPresentationIfNeeded(using: proxy)
            }
            .task(id: weatherTaskID) {
                await loadWeather()
                if AppStoreScreenshotSupport.requestedShot == .routeDetailsWeather {
                    scrollToScreenshotDetails(using: proxy)
                }
            }
        }
    }

    @ViewBuilder
    private var bannerSection: some View {
        if let bannerMessage,
           bannerMessage.text.trimmed.nilIfEmpty?.caseInsensitiveCompare("cancelled") != .orderedSame {
            Section {
                RouteEditorBanner(message: bannerMessage.text, tone: bannerMessage.tone)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
        }
    }

    @ViewBuilder
    private var mapSection: some View {
        Section {
            if route.routeCoordinates.isEmpty {
                ContentUnavailableView(
                    "Map Unavailable",
                    systemImage: "map",
                    description: Text("This route does not have enough geometry to render a map preview yet.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowBackground(Color.clear)
            } else {
                RouteDetailMapCard(
                    route: route,
                    activeElevationDistanceMeters: $activeElevationDistanceMeters,
                    lockedElevationDistanceMeters: $lockedElevationDistanceMeters,
                    activeElevationSample: activeElevationSample,
                    lockedElevationSample: lockedElevationSample,
                    isShowingElevationChart: isShowingElevationChart,
                    isLoadingElevationProfile: isLoadingElevationProfile,
                    elevationProfileStatusMessage: resolvedElevationProfileStatusMessage,
                    routeDetailsActionTitle: detailDownloadButtonTitle,
                    canDownloadRouteDetails: canDownloadRouteDetails,
                    onDownloadRouteDetails: {
                        presentDownloadOptions()
                    },
                    onToggleElevationChart: toggleElevationChartVisibility
                ) {
                    isShowingFullScreenMap = true
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            if offlineStatus.hasAnyAssets {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved Offline")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(offlineStatus.summaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Label(offlineStorageText, systemImage: "externaldrive")
                        if let downloadedAt = offlineStatus.downloadedAt {
                            Label("Updated \(RouteDisplayFormatter.calendarDate(downloadedAt))", systemImage: "clock")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Button(action: startActivity) {
                Label("Start Activity", systemImage: "figure.walk.motion")
            }
            .accessibilityIdentifier("route-editor-start-activity")
            .disabled(route.routeCoordinates.count < 2)

            if let url = route.routeURL {
                Link(destination: url) {
                    Label("Open in Strava", systemImage: "arrow.up.right.square")
                }
            }

            if !route.isImportedFromGPX {
                Button {
                    Task { await refreshRouteFromStrava() }
                } label: {
                    Label(isRefreshingRoute ? "Refreshing Route…" : "Refresh Route", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshingRoute)
            }

            Button(action: openStartInMaps) {
                Label("Open Start in Maps", systemImage: "location.fill.viewfinder")
            }
            .disabled(route.startCoordinate == nil)

            Button(action: presentDownloadOptions) {
                Label(detailDownloadButtonTitle, systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("route-editor-open-offline-download")
            .disabled(isDownloadDisabled)

            if route.hasOfflineAssets {
                Button(role: .destructive, action: removeOfflineDownload) {
                    Label("Remove Download", systemImage: "trash")
                }
                .accessibilityIdentifier("route-editor-remove-offline-download")
            }

            if let gpxURL = offlineAssetService.gpxURL(for: route) {
                ShareLink(item: gpxURL) {
                    Label("Share Saved GPX", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("route-editor-share-saved-gpx")
            }
        }
        .id("route-editor-actions-\(route.stravaRouteID)-\(offlineStatusRevision)")
    }

    private var overviewSection: some View {
        Section("Overview") {
            LabeledContent("Name", value: route.name)

            LabeledContent("Activity") {
                Menu {
                    ForEach(editableSportKinds) { sportKind in
                        Button {
                            updateSportKind(sportKind)
                        } label: {
                            if sportKind == route.sportKind {
                                Label(sportKind.title, systemImage: "checkmark")
                            } else {
                                Text(sportKind.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(route.sportDisplayName)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            LabeledContent("Distance", value: RouteDisplayFormatter.distance(route.distanceMeters))
            LabeledContent("Climb", value: RouteDisplayFormatter.climb(route.elevationGainMeters))
            LabeledContent("Estimated Time", value: RouteDisplayFormatter.duration(route.estimatedMovingTime))
            LabeledContent("Updated", value: RouteDisplayFormatter.absoluteDate(route.primaryTimestamp))
        }
    }

    private var weatherSection: some View {
        Section("Weather") {
            if weatherCoordinate == nil {
                Text("Weather will appear once this route has a valid start point.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(weatherLocationLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if let snapshot = weatherSnapshot {
                                Text("Updated \(RouteDisplayFormatter.relativeDate(snapshot.fetchedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Current conditions and the next few highs and lows for the route start area.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 12)

                        Button {
                            Task { await loadWeather(forceRefresh: true) }
                        } label: {
                            if isLoadingWeather {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingWeather)
                        .accessibilityLabel("Refresh weather")
                    }

                    if let snapshot = weatherSnapshot {
                        RouteWeatherSummaryCard(
                            symbolName: RouteWeatherCondition(weatherCode: snapshot.current.weatherCode)
                                .symbolName(isDaylight: snapshot.current.isDaylight),
                            conditionTitle: RouteWeatherCondition(weatherCode: snapshot.current.weatherCode).title,
                            temperatureText: RouteDisplayFormatter.weatherTemperature(snapshot.current.temperature),
                            apparentTemperatureText: RouteDisplayFormatter.weatherTemperature(snapshot.current.apparentTemperature),
                            observedTimeText: weatherTimeText(for: snapshot.current.observedAt, in: snapshot),
                            windText: RouteDisplayFormatter.weatherWindSpeed(snapshot.current.windSpeed),
                            humidityText: snapshot.current.humidityPercent.map(RouteDisplayFormatter.percent)
                        )

                        let forecastDays = weatherForecastDisplayDays(from: snapshot)
                        if !forecastDays.isEmpty {
                            RouteWeatherForecastStrip(days: forecastDays)
                        }
                    } else if isLoadingWeather {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading route weather…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let weatherStatusMessage = weatherStatusMessage {
                        RouteEditorBanner(message: weatherStatusMessage, tone: .error)

                        Button("Try Again") {
                            Task { await loadWeather(forceRefresh: true) }
                        }
                        .font(.footnote.weight(.semibold))
                    }

                    if let weatherStatusMessage = weatherStatusMessage,
                       weatherSnapshot != nil {
                        Label(weatherStatusMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }

                    Text("Forecast for the route start area via \(weatherSnapshot?.providerName ?? "Open-Meteo").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func applyScreenshotPresentationIfNeeded(using proxy: ScrollViewProxy) {
        guard !didApplyScreenshotPresentation else {
            return
        }

        didApplyScreenshotPresentation = true

        switch AppStoreScreenshotSupport.requestedShot {
        case .routeFullScreenMap:
            isShowingElevationChart = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                isShowingFullScreenMap = true
            }
        case .routeDetailsWeather:
            scrollToScreenshotDetails(using: proxy)
        default:
            break
        }
    }

    private func scrollToScreenshotDetails(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(ScreenshotAnchor.overviewSection.rawValue, anchor: .top)
            }
        }
    }

    private var editableSportKinds: [RouteSportKind] {
        RouteSportKind.allCases.filter { $0 != .other } + [.other]
    }

    private func updateSportKind(_ sportKind: RouteSportKind) {
        let mapping: (type: Int, subType: Int)
        switch sportKind {
        case .ride:
            mapping = (1, 1)
        case .mountainBike:
            mapping = (1, 2)
        case .mixedRide:
            mapping = (1, 5)
        case .gravelRide:
            mapping = (6, 4)
        case .cyclocross:
            mapping = (1, 3)
        case .run:
            mapping = (2, 1)
        case .trailRun:
            mapping = (2, 4)
        case .walk:
            mapping = (4, 1)
        case .hike:
            mapping = (4, 4)
        case .snowshoe:
            mapping = (4, 5)
        case .ski:
            mapping = (3, 1)
        case .wheelchair:
            mapping = (4, 2)
        case .other:
            mapping = (0, 0)
        }

        route.routeType = mapping.type
        route.routeSubType = mapping.subType
        route.updatedAt = .now
        try? modelContext.save()
    }

    private var organizationSection: some View {
        Section("Lists") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lists")
                            .font(.subheadline.weight(.semibold))

                        Text(listsSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Menu(content: listMenuContent) {
                        Label("Add to List", systemImage: "list.bullet")
                    }
                }

                if route.hasLists {
                    RouteListRow(listNames: route.listNames)
                } else {
                    Text("Use the menu to add this route to one or more lists or create a new list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes / Search Terms") {
            TextEditor(text: $route.notes)
                .frame(minHeight: 140)

            if !route.visibleSearchTerms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Search Terms")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    RouteSearchTermsGrid(terms: route.visibleSearchTerms)
                }
                .padding(.top, 4)
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("Delete Route", systemImage: "trash")
            }
        } footer: {
            Text("Last synced \(RouteDisplayFormatter.absoluteDate(route.syncedAt))")
                .textCase(nil)
        }
    }

    private var availableLists: [RouteList] {
        allLists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var listsSummary: String {
        route.hasLists
            ? "\(route.listNames.count) \(route.listNames.count == 1 ? "list" : "lists") assigned"
            : "Not in any lists"
    }

    private var activeElevationSample: RouteElevationSample? {
        route.elevationSample(closestToDistanceMeters: activeElevationDistanceMeters)
    }

    private var lockedElevationSample: RouteElevationSample? {
        route.elevationSample(closestToDistanceMeters: lockedElevationDistanceMeters)
    }

    @ViewBuilder
    private func listMenuContent() -> some View {
        if availableLists.isEmpty {
            Button("No lists yet") { }
                .disabled(true)
        } else {
            Section("Add to Existing Lists") {
                ForEach(availableLists) { list in
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
        }

        Section {
            Button {
                newListDraft = ""
                isShowingNewListPrompt = true
            } label: {
                Label("Create New List", systemImage: "plus")
            }

            if route.hasLists {
                Button("Remove from All Lists", role: .destructive, action: clearAllLists)
            }
        }
    }

    private var downloadButtonTitle: String {
        if let offlineDownloadProgress {
            return offlineDownloadProgress.buttonLabel
        }

        if isDownloadingOffline {
            return "Preparing download"
        }

        return offlineStatus.hasAnyAssets ? "Manage Offline Download" : "Download Offline Files"
    }

    private var offlineStorageText: String {
        guard offlineStatus.totalBytes > 0 else {
            return offlineStatus.hasAnyAssets ? "Needs refresh" : "Not saved"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: offlineStatus.totalBytes)
    }

    private var isDownloadDisabled: Bool {
        isDownloadingOffline || (route.isImportedFromGPX && route.routeCoordinates.isEmpty)
    }

    private var canDownloadRouteDetails: Bool {
        !isDownloadDisabled
    }

    private var canDownloadMissingElevationProfile: Bool {
        !route.hasElevationProfile && !route.isImportedFromGPX && canDownloadRouteDetails
    }

    private var detailDownloadButtonTitle: String { downloadButtonTitle }

    private var startActivityWarningMessage: String {
        if route.isImportedFromGPX {
            return "This route does not include altitude data. You can still track the activity, but the elevation chart will stay unavailable for this session."
        }

        return "This route has not downloaded its elevation profile yet. You can still track the activity, but the elevation chart will stay unavailable until route data is downloaded."
    }

    private var resolvedElevationProfileStatusMessage: String? {
        if let elevationProfileStatusMessage = elevationProfileStatusMessage?.trimmed.nilIfEmpty {
            return elevationProfileStatusMessage
        }

        if route.hasElevationProfile {
            return nil
        }

        if route.isImportedFromGPX {
            return "This GPX route does not include altitude data."
        }

        return "Download route data to view the elevation profile. Add map files too if you want this route available offline."
    }

    private var deleteConfirmationMessage: String {
        if route.isImportedFromGPX {
            return "This removes the imported route from your local library."
        }

        return "This removes the route from your local library and keeps it out of future Strava syncs until you undelete it from Deleted Routes in settings."
    }

    private var appMeasurementSystem: AppMeasurementSystem {
        AppMeasurementSystem(rawValue: appMeasurementSystemRawValue) ?? .defaultValue
    }

    private var weatherCoordinate: CLLocationCoordinate2D? {
        route.startCoordinate
    }

    private var weatherLocationLabel: String {
        route.startAddressText ?? route.displayLocation.nilIfEmpty ?? "Route start area"
    }

    private var weatherTaskID: String {
        let coordinateToken = weatherCoordinate.map {
            String(format: "%.4f,%.4f", $0.latitude, $0.longitude)
        } ?? "missing"
        return "\(route.stravaRouteID)-\(coordinateToken)-\(appMeasurementSystem.rawValue)"
    }

    private func saveAndDismiss() {
        try? modelContext.save()
        dismiss()
    }

    private func deleteRoute() {
        let routeToDelete = route
        onDelete(routeToDelete)
        dismiss()
    }

    private func toggleList(_ list: RouteList) {
        route.listNames = route.toggledListNames(with: list.name)
        persistRouteChanges()
    }

    private func clearAllLists() {
        route.listNames = []
        persistRouteChanges()
    }

    private func addNewList() {
        let trimmedListName = newListDraft.trimmed
        guard !trimmedListName.isEmpty else {
            return
        }

        if let existingList = availableLists.first(where: { $0.normalizedName == trimmedListName.routeLabelIdentifier }) {
            route.listNames = RouteRecord.normalizedLabels(route.listNames + [existingList.name])
            newListDraft = ""
            persistRouteChanges()
            return
        }

        let newList = RouteList(name: trimmedListName)
        modelContext.insert(newList)
        route.listNames = RouteRecord.normalizedLabels(route.listNames + [newList.name])
        newListDraft = ""
        persistRouteChanges()
    }

    private func refreshRouteFromStrava() async {
        guard !isRefreshingRoute else {
            return
        }

        isRefreshingRoute = true
        bannerMessage = nil
        defer { isRefreshingRoute = false }

        do {
            guard let storedSession = try credentialStore.loadSession() else {
                throw RouteActionError.notConnected
            }

            guard let credentials = try credentialStore.loadCredentials() else {
                throw StravaAPIService.APIError.missingCredentials
            }

            let activeSession = try await apiService.refreshedSessionIfNeeded(storedSession, credentials: credentials)
            try credentialStore.save(session: activeSession)

            let remoteRoute = try await apiService.fetchRoute(routeID: route.stravaRouteID, accessToken: activeSession.accessToken)
            route.apply(remote: remoteRoute, syncedAt: .now)

            do {
                let gpxData = try await fetchGPXFromStrava()
                let importedRoute = try await gpxImportService.importRoute(from: gpxData, suggestedName: remoteRoute.name)
                route.apply(importedGPX: importedRoute, syncedAt: .now)
            } catch RouteActionError.privateRouteRequiresReadAll {
                bannerMessage = BannerMessage(
                    text: "Refreshed route details. Exact GPX geometry still needs Strava `read_all` access.",
                    tone: .success
                )
            } catch {
                // Keep the metadata refresh successful even if GPX export is unavailable for this route.
            }

            persistRouteChanges()

            if bannerMessage == nil {
                bannerMessage = BannerMessage(
                    text: "Route refreshed from Strava.",
                    tone: .success
                )
            }
        } catch {
            invalidateSessionIfNeeded(for: error)
            bannerMessage = BannerMessage(
                text: displayMessage(for: error),
                tone: .error
            )
        }
    }

    private func openStartInMaps() {
        guard let coordinate = route.startCoordinate else {
            return
        }

        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = route.displayLocation.nilIfEmpty ?? route.name
        mapItem.openInMaps(launchOptions: nil)
    }

    private func startActivity() {
        guard route.routeCoordinates.count > 1 else {
            bannerMessage = BannerMessage(
                text: "This route does not have enough geometry to start a tracked activity.",
                tone: .error
            )
            return
        }

        guard route.hasElevationProfile else {
            isShowingStartActivityWarning = true
            return
        }

        beginActivityTracking()
    }

    private func beginActivityTracking() {
        activeRouteTrackingRouteID = route.stravaRouteID
        dismiss()
    }

    private func toggleElevationChartVisibility() {
        let nextVisibility = !isShowingElevationChart

        withAnimation(.easeInOut(duration: 0.22)) {
            isShowingElevationChart = nextVisibility
            if !nextVisibility {
                activeElevationDistanceMeters = nil
                lockedElevationDistanceMeters = nil
            }
        }
    }

    private var currentAppRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private func presentDownloadOptions() {
        let downloadedStyles = offlineStatus.mapStyles
        let hasSavedGPX = offlineStatus.hasGPX
        offlineDownloadSelection = RouteOfflineDownloadSelection(
            includesGPX: hasSavedGPX || downloadedStyles.isEmpty,
            mapStyles: downloadedStyles.isEmpty ? (hasSavedGPX ? [] : [currentAppRouteMapStyle]) : downloadedStyles,
            includesTerrain: offlineStatus.includesTerrain
        )
        isShowingDownloadOptions = true
    }

    @MainActor
    private func downloadOfflineBundle(using selection: RouteOfflineDownloadSelection) async {
        guard !isDownloadingOffline else {
            return
        }

        guard selection.hasDownloadableSelection else {
            bannerMessage = BannerMessage(text: "Choose at least one route file or map option to download.", tone: .error)
            return
        }

        if let retryAfter = await elevationBackfillCoordinator.retryAfter(for: route.stravaRouteID) {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            let retryText = formatter.string(from: retryAfter)
            elevationProfileStatusMessage = "Strava is rate-limiting route-detail downloads right now. Try again after \(retryText)."
            bannerMessage = BannerMessage(text: elevationProfileStatusMessage ?? "Try again later.", tone: .error)
            return
        }

        isDownloadingOffline = true
        isLoadingElevationProfile = true
        isShowingDownloadOptions = false
        offlineDownloadProgress = RouteOfflineDownloadProgress(message: "Preparing download", fractionCompleted: 0)
        bannerMessage = nil
        elevationProfileStatusMessage = nil
        defer {
            isDownloadingOffline = false
            isLoadingElevationProfile = false
            offlineDownloadProgress = nil
        }

        do {
            let storedAssets = try await routeDetailDownloadCoordinator.downloadRouteDetails(
                for: route,
                selection: selection,
                progress: { progress in
                    Task { @MainActor in
                        offlineDownloadProgress = progress
                    }
                }
            )

            route.offlineGPXRelativePath = storedAssets.gpxRelativePath
            route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
            route.offlineDownloadedAt = storedAssets.downloadedAt

            try modelContext.save()
            offlineStatusRevision += 1
            await elevationBackfillCoordinator.clearRetryAfter(for: route.stravaRouteID)
            let savedOfflineSummary = offlineStatus.summaryText
            elevationProfileStatusMessage = route.hasElevationProfile
                ? nil
                : "Route details were downloaded, but Strava did not include altitude samples for this route."
            bannerMessage = BannerMessage(
                text: route.hasElevationProfile
                    ? "Saved offline files: \(savedOfflineSummary)."
                    : "Saved offline files: \(savedOfflineSummary). No altitude samples were available for the elevation chart.",
                tone: .success
            )
        } catch {
            if case let StravaAPIService.APIError.rateLimited(_, retryAfter) = error {
                await elevationBackfillCoordinator.setRetryAfter(retryAfter, for: route.stravaRouteID)
            }
            elevationProfileStatusMessage = displayMessage(for: error)
            bannerMessage = BannerMessage(text: displayMessage(for: error), tone: .error)
        }
    }

    private func removeOfflineDownload() {
        bannerMessage = nil

        do {
            try offlineAssetService.removeOfflineAssets(for: route)
            route.offlineGPXRelativePath = nil
            route.offlineMapSnapshotRelativePath = nil
            route.offlineDownloadedAt = nil
            try modelContext.save()
            offlineStatusRevision += 1
            bannerMessage = BannerMessage(
                text: "Removed the saved offline files for this route.",
                tone: .success
            )
        } catch {
            bannerMessage = BannerMessage(text: displayMessage(for: error), tone: .error)
        }
    }

    private func fetchGPXFromStrava() async throws -> Data {
        guard let credentials = try credentialStore.loadCredentials(),
              var session = try credentialStore.loadSession() else {
            throw RouteActionError.notConnected
        }

        if route.isPrivate && !session.hasReadAllAccess {
            throw RouteActionError.privateRouteRequiresReadAll
        }

        do {
            session = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials)
            let gpxData = try await apiService.fetchRouteGPX(routeID: route.stravaRouteID, accessToken: session.accessToken)
            try credentialStore.save(session: session)
            return gpxData
        } catch StravaAPIService.APIError.unauthorized {
            session = try await apiService.refreshedSessionIfNeeded(session, credentials: credentials, forceRefresh: true)
            let gpxData = try await apiService.fetchRouteGPX(routeID: route.stravaRouteID, accessToken: session.accessToken)
            try credentialStore.save(session: session)
            return gpxData
        } catch {
            invalidateSessionIfNeeded(for: error)
            throw error
        }
    }

    private func displayMessage(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    private func invalidateSessionIfNeeded(for error: Error) {
        guard let apiError = error as? StravaAPIService.APIError,
              apiError.requiresSessionReset else {
            return
        }

        try? credentialStore.clearSession()
    }

    private func persistRouteChanges() {
        try? modelContext.save()
    }

    @MainActor
    private func loadWeather(forceRefresh: Bool = false) async {
        guard let coordinate = weatherCoordinate else {
            weatherSnapshot = nil
            weatherStatusMessage = nil
            isLoadingWeather = false
            return
        }

        if forceRefresh || weatherSnapshot == nil {
            isLoadingWeather = true
        }

        defer { isLoadingWeather = false }

        do {
            let snapshot = try await weatherService.weather(
                at: coordinate,
                measurementSystem: appMeasurementSystem,
                forceRefresh: forceRefresh
            )
            weatherSnapshot = snapshot
            weatherStatusMessage = snapshot.isStale
                ? "Showing the most recent saved forecast because the latest refresh did not complete."
                : nil
        } catch {
            if weatherSnapshot == nil {
                weatherStatusMessage = displayMessage(for: error)
            } else {
                weatherStatusMessage = "Couldn’t refresh weather right now. Showing the last forecast already saved on this device."
            }
        }
    }

    private func weatherTimeText(for date: Date, in snapshot: RouteWeatherSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func weatherForecastDisplayDays(from snapshot: RouteWeatherSnapshot) -> [RouteWeatherForecastDisplayDay] {
        let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .autoupdatingCurrent
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone

        let currentDay = calendar.startOfDay(for: snapshot.current.observedAt)
        let upcomingForecasts = snapshot.dailyForecasts
            .filter { calendar.startOfDay(for: $0.date) > currentDay }
        let selectedForecasts = upcomingForecasts.isEmpty
            ? Array(snapshot.dailyForecasts.prefix(4))
            : Array(upcomingForecasts.prefix(4))

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = .autoupdatingCurrent
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEE")

        return selectedForecasts.map { forecast in
            let condition = RouteWeatherCondition(weatherCode: forecast.weatherCode)
            return RouteWeatherForecastDisplayDay(
                date: forecast.date,
                title: weekdayFormatter.string(from: forecast.date),
                symbolName: condition.symbolName(isDaylight: true),
                highText: RouteDisplayFormatter.weatherTemperature(forecast.highTemperature),
                lowText: RouteDisplayFormatter.weatherTemperature(forecast.lowTemperature),
                accessibilityLabel: "\(weekdayFormatter.string(from: forecast.date)): high \(RouteDisplayFormatter.weatherTemperature(forecast.highTemperature, includeUnit: true)), low \(RouteDisplayFormatter.weatherTemperature(forecast.lowTemperature, includeUnit: true)), \(condition.title.lowercased())"
            )
        }
    }
}

enum RouteMapDisplayMode {
    case embedded
    case cardPreview
    case fullScreen

    var showsCompass: Bool {
        switch self {
        case .embedded:
            return false
        case .cardPreview:
            return false
        case .fullScreen:
            return true
        }
    }

    var showsScale: Bool {
        switch self {
        case .embedded:
            return false
        case .cardPreview:
            return false
        case .fullScreen:
            return true
        }
    }

    var allowsPitch: Bool {
        switch self {
        case .embedded:
            return false
        case .cardPreview:
            return false
        case .fullScreen:
            return true
        }
    }

    var allowsRotate: Bool {
        switch self {
        case .embedded:
            return false
        case .cardPreview:
            return false
        case .fullScreen:
            return true
        }
    }

    func edgePadding(fitInsets: RouteMapFitInsets) -> UIEdgeInsets {
        switch self {
        case .embedded:
            let isExpandedPreview = fitInsets == .expandedPreview
            return UIEdgeInsets(
                top: max(isExpandedPreview ? 8 : 10, fitInsets.top),
                left: isExpandedPreview ? 4 : 8,
                bottom: max(isExpandedPreview ? 8 : 18, fitInsets.bottom),
                right: isExpandedPreview ? 4 : 8
            )
        case .cardPreview:
            return UIEdgeInsets(
                top: max(4, fitInsets.top),
                left: 2,
                bottom: max(4, fitInsets.bottom),
                right: 2
            )
        case .fullScreen:
            return UIEdgeInsets(
                top: max(92, fitInsets.top),
                left: 14,
                bottom: max(24, fitInsets.bottom),
                right: 14
            )
        }
    }

    var paddingFactor: Double {
        switch self {
        case .embedded:
            return 0.01
        case .cardPreview:
            return 0.002
        case .fullScreen:
            return 0.03
        }
    }

    var minimumMapDimension: Double {
        switch self {
        case .embedded:
            return 220
        case .cardPreview:
            return 90
        case .fullScreen:
            return 320
        }
    }

    var maximumRouteFitZoom: Double {
        switch self {
        case .embedded:
            return 18.25
        case .cardPreview:
            return 19.4
        case .fullScreen:
            return 18.0
        }
    }
}

struct RouteMapFitInsets: Equatable {
    let top: CGFloat
    let bottom: CGFloat

    static let embedded = RouteMapFitInsets(top: 10, bottom: 18)
    static let expandedPreview = RouteMapFitInsets(top: 4, bottom: 4)
}

private struct RouteTopOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct RouteBottomOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct RouteEditorBanner: View {
    let message: String
    let tone: RouteEditorBannerTone

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .success:
            return Color(red: 0.18, green: 0.41, blue: 0.20)
        case .error:
            return Color(red: 0.67, green: 0.18, blue: 0.18)
        }
    }

    private var background: Color {
        switch tone {
        case .success:
            return Color(red: 0.88, green: 0.95, blue: 0.89)
        case .error:
            return Color(red: 0.99, green: 0.91, blue: 0.91)
        }
    }
}

private struct RouteWeatherForecastDisplayDay: Identifiable {
    let date: Date
    let title: String
    let symbolName: String
    let highText: String
    let lowText: String
    let accessibilityLabel: String

    var id: Date { date }
}

private struct RouteWeatherSummaryCard: View {
    let symbolName: String
    let conditionTitle: String
    let temperatureText: String
    let apparentTemperatureText: String
    let observedTimeText: String
    let windText: String
    let humidityText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.98, green: 0.79, blue: 0.41),
                                    Color(red: 0.95, green: 0.47, blue: 0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)

                    Image(systemName: symbolName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(conditionTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("As of \(observedTimeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(temperatureText)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Feels like \(apparentTemperatureText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                RouteWeatherMetricCapsule(title: "Wind", value: windText)

                if let humidityText {
                    RouteWeatherMetricCapsule(title: "Humidity", value: humidityText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

private struct RouteWeatherMetricCapsule: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

private struct RouteWeatherForecastStrip: View {
    let days: [RouteWeatherForecastDisplayDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next Few Days")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(days) { day in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(day.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Image(systemName: day.symbolName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color(red: 0.20, green: 0.41, blue: 0.78))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("H \(day.highText)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)

                                Text("L \(day.lowText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(width: 110, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(day.accessibilityLabel)
                    }
                }
            }
        }
    }
}

private struct RouteListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let listNames: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tagViews
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tagViews
                }
            }
        }
    }

    @ViewBuilder
    private var tagViews: some View {
        ForEach(listNames, id: \.self) { listName in
            Text(listName)
                .font(.caption.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.78) : Color(red: 0.43, green: 0.42, blue: 0.39))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color(red: 0.92, green: 0.90, blue: 0.86))
                )
        }
    }
}

private struct RouteSearchTermsGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    let terms: [String]

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 112, maximum: 220), spacing: 8, alignment: .leading)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(terms, id: \.self) { term in
                Text(term)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.78) : Color(red: 0.43, green: 0.42, blue: 0.39))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color(red: 0.92, green: 0.90, blue: 0.86))
                    )
            }
        }
    }
}

enum RouteElevationChartPanelStyle {
    case embedded
    case fullScreen
    case trackingCompact

    var chartHeight: CGFloat {
        switch self {
        case .embedded:
            return 112
        case .fullScreen:
            return 136
        case .trackingCompact:
            return 96
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .embedded:
            return 16
        case .fullScreen:
            return 18
        case .trackingCompact:
            return 12
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .embedded:
            return 12
        case .fullScreen:
            return 14
        case .trackingCompact:
            return 10
        }
    }

    var spacing: CGFloat {
        switch self {
        case .embedded:
            return 10
        case .fullScreen:
            return 12
        case .trackingCompact:
            return 8
        }
    }

    var maximumRenderedSamples: Int {
        switch self {
        case .embedded:
            return 180
        case .fullScreen:
            return 260
        case .trackingCompact:
            return 150
        }
    }
}

private struct RouteDetailMapCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var fitTrigger = 0

    let route: RouteRecord
    @Binding var activeElevationDistanceMeters: Double?
    @Binding var lockedElevationDistanceMeters: Double?
    let activeElevationSample: RouteElevationSample?
    let lockedElevationSample: RouteElevationSample?
    let isShowingElevationChart: Bool
    let isLoadingElevationProfile: Bool
    let elevationProfileStatusMessage: String?
    let routeDetailsActionTitle: String
    let canDownloadRouteDetails: Bool
    let onDownloadRouteDetails: () -> Void
    let onToggleElevationChart: () -> Void
    let onOpenFullScreen: () -> Void

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    private var cardFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.92)
    }

    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RouteMapSurface(
                    route: route,
                    displayMode: .embedded,
                    routeFitInsets: RouteMapFitInsets(top: 10, bottom: isShowingElevationChart ? 18 : 16),
                    activeElevationSample: activeElevationSample,
                    lockedElevationSample: lockedElevationSample,
                    fitTrigger: fitTrigger
                )
                .frame(height: 250)
                .clipped()

                Rectangle()
                    .fill(cardFillColor)
                    .frame(height: 7)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                HStack(spacing: 10) {
                    RouteMapSettingsButton()

                    Button {
                        fitTrigger += 1
                    } label: {
                        Image(systemName: "scope")
                            .font(.headline.weight(.bold))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recenter route")

                    Button(action: onToggleElevationChart) {
                        Image(systemName: isShowingElevationChart ? "eye.slash" : "eye")
                            .font(.headline.weight(.bold))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isShowingElevationChart ? "Hide elevation chart" : "Show elevation chart")

                    Button(action: onOpenFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.headline.weight(.bold))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open full screen map")
                }
                .padding(12)
            }

            if isShowingElevationChart {
                Divider()
                    .overlay(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))

                RouteElevationChartPanel(
                    route: route,
                    activeDistanceMeters: $activeElevationDistanceMeters,
                    lockedDistanceMeters: $lockedElevationDistanceMeters,
                    panelStyle: .embedded,
                    isLoading: isLoadingElevationProfile,
                    unavailableMessage: elevationProfileStatusMessage,
                    primaryActionTitle: canDownloadRouteDetails ? routeDetailsActionTitle : nil,
                    onPrimaryAction: canDownloadRouteDetails ? onDownloadRouteDetails : nil
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            cardShape
                .fill(cardFillColor)
        )
        .overlay {
            cardShape
                .strokeBorder(cardStrokeColor, lineWidth: 1)
        }
        .clipShape(cardShape)
    }
}


struct RouteElevationChartPanel: View {
    private struct ComparisonMetrics {
        let distanceMeters: Double
        let elevationGainMeters: Double
        let elevationLossMeters: Double
        let averageGradeFraction: Double
    }

    @Environment(\.colorScheme) private var colorScheme

    let route: RouteRecord
    @Binding var activeDistanceMeters: Double?
    @Binding var lockedDistanceMeters: Double?
    let panelStyle: RouteElevationChartPanelStyle
    let isLoading: Bool
    let unavailableMessage: String?
    let primaryActionTitle: String?
    let onPrimaryAction: (() -> Void)?
    let currentProgressDistanceMeters: Double?
    let onToggleVisibility: (() -> Void)?
    let sampleOverride: [RouteElevationSample]?

    @State private var fullSamples: [RouteElevationSample]
    @State private var displaySamples: [RouteElevationSample]
    @State private var zoomDistanceRange: ClosedRange<Double>?
    @State private var pinchBaseDistanceRange: ClosedRange<Double>?
    @State private var pinchAnchorDistance: Double?

    init(
        route: RouteRecord,
        activeDistanceMeters: Binding<Double?>,
        lockedDistanceMeters: Binding<Double?>,
        panelStyle: RouteElevationChartPanelStyle,
        isLoading: Bool,
        unavailableMessage: String?,
        primaryActionTitle: String? = nil,
        onPrimaryAction: (() -> Void)? = nil,
        currentProgressDistanceMeters: Double? = nil,
        onToggleVisibility: (() -> Void)? = nil,
        sampleOverride: [RouteElevationSample]? = nil
    ) {
        self.route = route
        self._activeDistanceMeters = activeDistanceMeters
        self._lockedDistanceMeters = lockedDistanceMeters
        self.panelStyle = panelStyle
        self.isLoading = isLoading
        self.unavailableMessage = unavailableMessage
        self.primaryActionTitle = primaryActionTitle
        self.onPrimaryAction = onPrimaryAction
        self.currentProgressDistanceMeters = currentProgressDistanceMeters
        self.onToggleVisibility = onToggleVisibility
        self.sampleOverride = sampleOverride

        let initialSamples = sampleOverride ?? route.elevationProfile
        self._fullSamples = State(initialValue: initialSamples)
        self._displaySamples = State(
            initialValue: Self.decimatedSamples(from: initialSamples, maxCount: panelStyle.maximumRenderedSamples)
        )
    }

    private var activeSample: RouteElevationSample? {
        Self.nearestSample(in: fullSamples, to: activeDistanceMeters)
    }

    private var lockedSample: RouteElevationSample? {
        Self.nearestSample(in: fullSamples, to: lockedDistanceMeters)
    }

    private var progressSample: RouteElevationSample? {
        Self.nearestSample(in: fullSamples, to: currentProgressDistanceMeters)
    }

    private var displayedSample: RouteElevationSample? {
        activeSample ?? lockedSample ?? progressSample
    }

    private var fullDistanceRange: ClosedRange<Double> {
        let maximumDistance = max(route.distanceMeters, fullSamples.last?.distanceMeters ?? route.distanceMeters, 1)
        return 0...maximumDistance
    }

    private var currentDistanceRange: ClosedRange<Double> {
        zoomDistanceRange ?? fullDistanceRange
    }

    private var isZoomed: Bool {
        let fullSpan = fullDistanceRange.upperBound - fullDistanceRange.lowerBound
        let currentSpan = currentDistanceRange.upperBound - currentDistanceRange.lowerBound
        return currentSpan < (fullSpan - max(1, fullSpan * 0.01))
    }

    private var minimumZoomSpan: Double {
        max(fullDistanceRange.upperBound * 0.04, 400)
    }

    private var defaultAverageGradeFraction: Double {
        guard route.distanceMeters > 0 else {
            return 0
        }

        return route.elevationGainMeters / route.distanceMeters
    }

    private var displayedGradeFraction: Double {
        if let sample = displayedSample {
            return gradeFraction(near: sample.distanceMeters) ?? defaultAverageGradeFraction
        }

        return defaultAverageGradeFraction
    }

    private var elevationExtrema: (minimum: Double, maximum: Double) {
        guard let firstSample = fullSamples.first else {
            return (0, 0)
        }

        var minimum = firstSample.elevationMeters
        var maximum = firstSample.elevationMeters

        for sample in fullSamples.dropFirst() {
            minimum = min(minimum, sample.elevationMeters)
            maximum = max(maximum, sample.elevationMeters)
        }

        return (minimum, maximum)
    }

    private var maxAltitudeMeters: Double {
        elevationExtrema.maximum
    }

    private var elevationDomain: ClosedRange<Double> {
        let minimum = elevationExtrema.minimum
        let maximum = elevationExtrema.maximum
        let padding = max((maximum - minimum) * 0.12, 24)
        return (minimum - padding)...(maximum + padding)
    }

    private var sampleCacheKey: String {
        if let sampleOverride {
            let lastSample = sampleOverride.last
            return "override-\(sampleOverride.count)-\(lastSample?.distanceMeters ?? 0)-\(lastSample?.elevationMeters ?? 0)-\(panelStyle.maximumRenderedSamples)"
        }

        return "\(route.elevationProfileBlob ?? "none")-\(panelStyle.maximumRenderedSamples)"
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Text("Elevation Profile")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if fullSamples.count > 1 {
                    Button {
                        lockCurrentMarker()
                    } label: {
                        Image(systemName: lockedSample == nil ? "lock" : "lock.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activeSample == nil || lockedSample != nil)
                    .accessibilityLabel(lockedSample == nil ? "Lock marker" : "Marker locked")

                    Button {
                        resetChartState()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activeSample == nil && lockedSample == nil && !isZoomed)
                    .accessibilityLabel("Reset chart")
                }

                if let onToggleVisibility {
                    Button(action: onToggleVisibility) {
                        Image(systemName: "eye.slash")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Hide elevation chart")
                }
            }
        }
    }

    private var comparisonMetrics: ComparisonMetrics? {
        guard let lockedDistanceMeters,
              let activeDistanceMeters else {
            return nil
        }

        return Self.comparisonMetrics(
            in: fullSamples,
            from: lockedDistanceMeters,
            to: activeDistanceMeters
        )
    }

    private var currentSelectionComparisonMetrics: ComparisonMetrics? {
        guard let currentProgressDistanceMeters,
              let selectedDistanceMeters = activeDistanceMeters ?? lockedDistanceMeters,
              abs(selectedDistanceMeters - currentProgressDistanceMeters) >= 1 else {
            return nil
        }

        return Self.comparisonMetrics(
            in: fullSamples,
            from: currentProgressDistanceMeters,
            to: selectedDistanceMeters
        )
    }

    var body: some View {
        Group {
            if fullSamples.count > 1 {
                VStack(alignment: .leading, spacing: panelStyle.spacing) {
                    panelHeader

                    HStack(spacing: 12) {
                        RouteElevationReadout(
                            title: "Distance",
                            value: RouteDisplayFormatter.distance(displayedSample?.distanceMeters ?? route.distanceMeters)
                        )

                        RouteElevationReadout(
                            title: displayedSample == nil ? "Elevation Gain" : "Altitude",
                            value: displayedSample == nil
                                ? RouteDisplayFormatter.climb(route.elevationGainMeters)
                                : RouteDisplayFormatter.altitude(displayedSample?.elevationMeters ?? maxAltitudeMeters)
                        )

                        RouteElevationReadout(
                            title: "Grade",
                            value: RouteDisplayFormatter.grade(displayedGradeFraction)
                        )
                    }

                    if let currentSelectionComparisonMetrics {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("From Current Position")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            HStack(spacing: 12) {
                                RouteElevationReadout(
                                    title: "Distance",
                                    value: RouteDisplayFormatter.distance(currentSelectionComparisonMetrics.distanceMeters)
                                )
                                RouteElevationReadout(
                                    title: "Gain",
                                    value: RouteDisplayFormatter.climb(currentSelectionComparisonMetrics.elevationGainMeters)
                                )
                                RouteElevationReadout(
                                    title: "Loss",
                                    value: RouteDisplayFormatter.climb(currentSelectionComparisonMetrics.elevationLossMeters)
                                )
                                RouteElevationReadout(
                                    title: "Avg Grade",
                                    value: RouteDisplayFormatter.grade(currentSelectionComparisonMetrics.averageGradeFraction)
                                )
                            }
                        }
                    } else if let comparisonMetrics {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Between Markers")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            HStack(spacing: 12) {
                                RouteElevationReadout(
                                    title: "Distance",
                                    value: RouteDisplayFormatter.distance(comparisonMetrics.distanceMeters)
                                )
                                RouteElevationReadout(
                                    title: "Gain",
                                    value: RouteDisplayFormatter.climb(comparisonMetrics.elevationGainMeters)
                                )
                                RouteElevationReadout(
                                    title: "Loss",
                                    value: RouteDisplayFormatter.climb(comparisonMetrics.elevationLossMeters)
                                )

                                RouteElevationReadout(
                                    title: "Avg Grade",
                                    value: RouteDisplayFormatter.grade(comparisonMetrics.averageGradeFraction)
                                )
                            }
                        }
                    }

                    Chart(displaySamples) { sample in
                        AreaMark(
                            x: .value("Distance", sample.distanceMeters),
                            y: .value("Altitude", sample.elevationMeters)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.orange.opacity(colorScheme == .dark ? 0.44 : 0.30),
                                    Color.orange.opacity(0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Distance", sample.distanceMeters),
                            y: .value("Altitude", sample.elevationMeters)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.orange)

                        if let lockedSample {
                            RuleMark(x: .value("Distance", lockedSample.distanceMeters))
                                .foregroundStyle(Color.blue.opacity(0.28))
                                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 3]))

                            PointMark(
                                x: .value("Distance", lockedSample.distanceMeters),
                                y: .value("Altitude", lockedSample.elevationMeters)
                            )
                            .symbolSize(58)
                            .foregroundStyle(Color.blue)
                        }

                        if let activeSample {
                            RuleMark(x: .value("Distance", activeSample.distanceMeters))
                                .foregroundStyle(Color.orange.opacity(0.32))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                            PointMark(
                                x: .value("Distance", activeSample.distanceMeters),
                                y: .value("Altitude", activeSample.elevationMeters)
                            )
                            .symbolSize(64)
                            .foregroundStyle(Color.orange)
                        }

                        if let progressSample {
                            RuleMark(x: .value("Distance", progressSample.distanceMeters))
                                .foregroundStyle(Color(red: 0.16, green: 0.82, blue: 0.68).opacity(0.32))
                                .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [2, 3]))

                            PointMark(
                                x: .value("Distance", progressSample.distanceMeters),
                                y: .value("Altitude", progressSample.elevationMeters)
                            )
                            .symbolSize(52)
                            .foregroundStyle(Color(red: 0.16, green: 0.82, blue: 0.68))
                        }
                    }
                    .chartXScale(domain: currentDistanceRange)
                    .chartYScale(domain: elevationDomain)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.16))
                            AxisTick()
                                .foregroundStyle(Color.secondary.opacity(0.24))
                            AxisValueLabel {
                                if let meters = value.as(Double.self) {
                                    Text(axisDistanceLabel(for: meters))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.16))
                            AxisTick()
                                .foregroundStyle(Color.secondary.opacity(0.24))
                            AxisValueLabel {
                                if let meters = value.as(Double.self) {
                                    Text(axisAltitudeLabel(for: meters))
                                }
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    SpatialTapGesture()
                                        .onEnded { value in
                                            updateSelection(
                                                at: value.location,
                                                proxy: proxy,
                                                geometry: geometry,
                                                clearsOutsidePlot: true
                                            )
                                        }
                                )
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 6)
                                        .onChanged { value in
                                            updateSelection(
                                                at: value.location,
                                                proxy: proxy,
                                                geometry: geometry,
                                                clearsOutsidePlot: false
                                            )
                                        }
                                        .onEnded { value in
                                            updateSelection(
                                                at: value.location,
                                                proxy: proxy,
                                                geometry: geometry,
                                                clearsOutsidePlot: true
                                            )
                                        }
                                )
                                .simultaneousGesture(
                                    MagnifyGesture()
                                        .onChanged { value in
                                            updateZoom(
                                                with: value,
                                                proxy: proxy,
                                                geometry: geometry
                                            )
                                        }
                                        .onEnded { _ in
                                            pinchBaseDistanceRange = nil
                                            pinchAnchorDistance = nil
                                        }
                                )
                        }
                    }
                    .frame(height: panelStyle.chartHeight)
                }
                .padding(.horizontal, panelStyle.horizontalPadding)
                .padding(.vertical, panelStyle.verticalPadding)
            } else if isLoading {
                VStack(alignment: .leading, spacing: 10) {
                    panelHeader

                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading elevation profile from Strava...")
                            .font(.subheadline.weight(.semibold))
                    }

                    Text("Distance and altitude will appear here as soon as GPX altitude data is available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, panelStyle.horizontalPadding)
                .padding(.vertical, panelStyle.verticalPadding)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    panelHeader
                    Text(unavailableMessage ?? "Could not load altitude data for this route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let primaryActionTitle,
                       let onPrimaryAction {
                        Button(action: onPrimaryAction) {
                            Text(primaryActionTitle)
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, panelStyle.horizontalPadding)
                .padding(.vertical, panelStyle.verticalPadding)
            }
        }
        .task(id: sampleCacheKey) {
            refreshSampleCaches()
        }
    }

    private func updateSelection(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        clearsOutsidePlot: Bool
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            if clearsOutsidePlot {
                clearSelection()
            }
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.width > 0 else {
            if clearsOutsidePlot {
                clearSelection()
            }
            return
        }

        guard plotFrame.contains(location) else {
            if clearsOutsidePlot {
                clearSelection()
            }
            return
        }

        let localX = location.x - plotFrame.minX
        guard let rawDistance = proxy.value(atX: localX, as: Double.self),
              let nearestDistance = nearestDistance(to: rawDistance) else {
            return
        }

        updateActiveDistance(nearestDistance)
    }

    private func refreshSampleCaches() {
        let refreshedSamples = sampleOverride ?? route.elevationProfile
        fullSamples = refreshedSamples
        if let zoomDistanceRange {
            self.zoomDistanceRange = clampedDistanceRange(zoomDistanceRange)
        }
        refreshDisplaySamples()

        if let lockedDistanceMeters,
           let resolvedDistance = nearestDistance(to: lockedDistanceMeters) {
            updateLockedDistance(resolvedDistance)
        }

        if let activeDistanceMeters,
           let resolvedDistance = nearestDistance(to: activeDistanceMeters) {
            updateActiveDistance(resolvedDistance)
        } else if refreshedSamples.count <= 1 {
            resetMarkers()
        }
    }

    private func lockCurrentMarker() {
        guard lockedSample == nil,
              let activeSample else {
            return
        }

        updateLockedDistance(activeSample.distanceMeters)
        updateActiveDistance(nil)
    }

    private func resetMarkers() {
        updateLockedDistance(nil)
        updateActiveDistance(nil)
    }

    private func resetChartState() {
        resetMarkers()
        updateZoomDistanceRange(nil)
        pinchBaseDistanceRange = nil
        pinchAnchorDistance = nil
    }

    private func updateActiveDistance(_ distanceMeters: Double?) {
        guard activeDistanceMeters != distanceMeters else {
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            activeDistanceMeters = distanceMeters
        }
    }

    private func updateLockedDistance(_ distanceMeters: Double?) {
        guard lockedDistanceMeters != distanceMeters else {
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            lockedDistanceMeters = distanceMeters
        }
    }

    private func clearSelection() {
        updateActiveDistance(nil)
    }

    private func updateZoom(
        with value: MagnifyGesture.Value,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.width > 0 else {
            return
        }

        let baseRange: ClosedRange<Double>
        if let pinchBaseDistanceRange {
            baseRange = pinchBaseDistanceRange
        } else {
            let currentRange = currentDistanceRange
            pinchBaseDistanceRange = currentRange
            baseRange = currentRange
        }

        let anchorDistance: Double
        if let pinchAnchorDistance {
            anchorDistance = pinchAnchorDistance
        } else {
            let anchorX = min(max(value.startLocation.x, plotFrame.minX), plotFrame.maxX) - plotFrame.minX
            let resolvedAnchorDistance = proxy.value(atX: anchorX, as: Double.self)
                ?? ((baseRange.lowerBound + baseRange.upperBound) / 2)
            let clampedAnchorDistance = min(max(resolvedAnchorDistance, baseRange.lowerBound), baseRange.upperBound)
            pinchAnchorDistance = clampedAnchorDistance
            anchorDistance = clampedAnchorDistance
        }

        let baseSpan = baseRange.upperBound - baseRange.lowerBound
        guard baseSpan > 0 else {
            return
        }

        let fullSpan = fullDistanceRange.upperBound - fullDistanceRange.lowerBound
        let proposedSpan = min(
            max(baseSpan / max(value.magnification, 0.01), minimumZoomSpan),
            fullSpan
        )
        let anchorFraction = min(max((anchorDistance - baseRange.lowerBound) / baseSpan, 0), 1)
        let proposedLower = anchorDistance - (anchorFraction * proposedSpan)
        let proposedUpper = proposedLower + proposedSpan
        updateZoomDistanceRange(clampedDistanceRange(proposedLower...proposedUpper))
    }

    private func updateZoomDistanceRange(_ range: ClosedRange<Double>?) {
        let normalizedRange: ClosedRange<Double>?

        if let range {
            let clampedRange = clampedDistanceRange(range)
            let fullSpan = fullDistanceRange.upperBound - fullDistanceRange.lowerBound
            let clampedSpan = clampedRange.upperBound - clampedRange.lowerBound
            normalizedRange = clampedSpan < (fullSpan - max(1, fullSpan * 0.01)) ? clampedRange : nil
        } else {
            normalizedRange = nil
        }

        guard zoomDistanceRange != normalizedRange else {
            return
        }

        zoomDistanceRange = normalizedRange
        refreshDisplaySamples()
    }

    private func clampedDistanceRange(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        let fullLower = fullDistanceRange.lowerBound
        let fullUpper = fullDistanceRange.upperBound
        let fullSpan = fullUpper - fullLower
        let requestedSpan = min(max(range.upperBound - range.lowerBound, minimumZoomSpan), fullSpan)
        let boundedLower = min(max(range.lowerBound, fullLower), fullUpper - requestedSpan)
        return boundedLower...(boundedLower + requestedSpan)
    }

    private func refreshDisplaySamples() {
        let visibleSamples = Self.visibleSamples(in: fullSamples, within: currentDistanceRange)
        displaySamples = Self.decimatedSamples(from: visibleSamples, maxCount: panelStyle.maximumRenderedSamples)
    }

    private func nearestDistance(to distanceMeters: Double) -> Double? {
        Self.nearestSample(in: fullSamples, to: distanceMeters)?.distanceMeters
    }

    private static func nearestSample(
        in samples: [RouteElevationSample],
        to distanceMeters: Double?
    ) -> RouteElevationSample? {
        guard let distanceMeters,
              let nearestIndex = nearestSampleIndex(in: samples, to: distanceMeters) else {
            return nil
        }

        return samples[nearestIndex]
    }

    private static func nearestSampleIndex(
        in samples: [RouteElevationSample],
        to distanceMeters: Double
    ) -> Int? {
        guard !samples.isEmpty else {
            return nil
        }

        guard samples.count > 1 else {
            return samples.startIndex
        }

        var lowerIndex = 0
        var upperIndex = samples.count - 1

        while lowerIndex < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2

            if samples[middleIndex].distanceMeters < distanceMeters {
                lowerIndex = middleIndex + 1
            } else {
                upperIndex = middleIndex
            }
        }

        if lowerIndex == 0 {
            return lowerIndex
        }

        let upperSample = samples[lowerIndex]
        let lowerSample = samples[lowerIndex - 1]
        return abs(lowerSample.distanceMeters - distanceMeters) <= abs(upperSample.distanceMeters - distanceMeters)
            ? (lowerIndex - 1)
            : lowerIndex
    }

    private static func comparisonMetrics(
        in samples: [RouteElevationSample],
        from startDistanceMeters: Double,
        to endDistanceMeters: Double
    ) -> ComparisonMetrics? {
        guard let firstIndex = nearestSampleIndex(in: samples, to: startDistanceMeters),
              let secondIndex = nearestSampleIndex(in: samples, to: endDistanceMeters) else {
            return nil
        }

        let lowerIndex = min(firstIndex, secondIndex)
        let upperIndex = max(firstIndex, secondIndex)

        let segmentDistance = abs(samples[upperIndex].distanceMeters - samples[lowerIndex].distanceMeters)
        var gainMeters = 0.0
        var lossMeters = 0.0

        if lowerIndex < upperIndex {
            for index in lowerIndex..<upperIndex {
                let delta = samples[index + 1].elevationMeters - samples[index].elevationMeters
                if delta > 0 {
                    gainMeters += delta
                } else if delta < 0 {
                    lossMeters += abs(delta)
                }
            }
        }

        return ComparisonMetrics(
            distanceMeters: segmentDistance,
            elevationGainMeters: gainMeters,
            elevationLossMeters: lossMeters,
            averageGradeFraction: segmentDistance > 0 ? gainMeters / segmentDistance : 0
        )
    }

    private func gradeFraction(near distanceMeters: Double) -> Double? {
        guard let sampleIndex = Self.nearestSampleIndex(in: fullSamples, to: distanceMeters) else {
            return nil
        }

        let lowerIndex = max(sampleIndex - 1, 0)
        let upperIndex = min(sampleIndex + 1, fullSamples.count - 1)
        guard upperIndex != lowerIndex else {
            return nil
        }

        let lowerSample = fullSamples[lowerIndex]
        let upperSample = fullSamples[upperIndex]
        let segmentDistance = upperSample.distanceMeters - lowerSample.distanceMeters
        guard segmentDistance > 0 else {
            return nil
        }

        return (upperSample.elevationMeters - lowerSample.elevationMeters) / segmentDistance
    }

    private static func decimatedSamples(
        from samples: [RouteElevationSample],
        maxCount: Int
    ) -> [RouteElevationSample] {
        guard samples.count > maxCount, maxCount > 2 else {
            return samples
        }

        let lastIndex = samples.count - 1
        let stride = Double(lastIndex) / Double(maxCount - 1)
        var reducedSamples: [RouteElevationSample] = [samples[0]]
        var previousIndex = 0

        for position in 1..<(maxCount - 1) {
            let rawIndex = Int((Double(position) * stride).rounded())
            let boundedIndex = min(max(rawIndex, 1), lastIndex - 1)

            guard boundedIndex != previousIndex else {
                continue
            }

            reducedSamples.append(samples[boundedIndex])
            previousIndex = boundedIndex
        }

        if reducedSamples.last?.id != samples[lastIndex].id {
            reducedSamples.append(samples[lastIndex])
        }

        return reducedSamples
    }

    private static func visibleSamples(
        in samples: [RouteElevationSample],
        within distanceRange: ClosedRange<Double>
    ) -> [RouteElevationSample] {
        guard let firstSample = samples.first,
              let lastSample = samples.last else {
            return []
        }

        if distanceRange.lowerBound <= firstSample.distanceMeters &&
            distanceRange.upperBound >= lastSample.distanceMeters {
            return samples
        }

        guard let lowerAnchorIndex = nearestSampleIndex(in: samples, to: distanceRange.lowerBound),
              let upperAnchorIndex = nearestSampleIndex(in: samples, to: distanceRange.upperBound) else {
            return samples
        }

        let lowerIndex = max(0, min(lowerAnchorIndex, upperAnchorIndex) - 1)
        let upperIndex = min(samples.count - 1, max(lowerAnchorIndex, upperAnchorIndex) + 1)
        return Array(samples[lowerIndex...upperIndex])
    }

    private func axisDistanceLabel(for meters: Double) -> String {
        let value = RouteDisplayFormatter.distanceDisplayValue(forMeters: meters)
        let unit = RouteDisplayFormatter.measurementSystem.distanceUnitLabel
        let text: String

        if value >= 100 {
            text = "\(Int(value.rounded()))"
        } else if value >= 10 {
            text = String(format: "%.0f", value)
        } else {
            text = String(format: "%.1f", value)
        }

        return "\(text)\(unit)"
    }

    private func axisAltitudeLabel(for meters: Double) -> String {
        let value = RouteDisplayFormatter.climbDisplayValue(forMeters: meters)
        let unit = RouteDisplayFormatter.measurementSystem.climbUnitLabel
        let text: String

        if value >= 1_000 {
            text = "\(Int((value / 100).rounded() * 100))"
        } else {
            text = "\(Int(value.rounded()))"
        }

        return "\(text)\(unit)"
    }
}

private struct RouteElevationReadout: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RouteFullScreenMapView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var topOverlayHeight: CGFloat = 0
    @State private var bottomOverlayHeight: CGFloat = 0
    @State private var fitTrigger = 0
    let route: RouteRecord
    @Binding var activeElevationDistanceMeters: Double?
    @Binding var lockedElevationDistanceMeters: Double?
    let isShowingElevationChart: Bool
    let isLoadingElevationProfile: Bool
    let elevationProfileStatusMessage: String?
    let routeDetailsActionTitle: String
    let canDownloadRouteDetails: Bool
    let onDownloadRouteDetails: () -> Void
    let onToggleElevationChart: () -> Void

    private var activeElevationSample: RouteElevationSample? {
        route.elevationSample(closestToDistanceMeters: activeElevationDistanceMeters)
    }

    private var lockedElevationSample: RouteElevationSample? {
        route.elevationSample(closestToDistanceMeters: lockedElevationDistanceMeters)
    }

    private var screenshotPreviewSamples: [RouteElevationSample] {
        AppStoreScreenshotSupport.previewElevationProfile(for: route)
    }

    private var fullScreenRouteFitInsets: RouteMapFitInsets {
        let isScreenshotShot = AppStoreScreenshotSupport.requestedShot == .routeFullScreenMap
        let minimumTopInset: CGFloat = isScreenshotShot ? 92 : 136
        let topInset = max(minimumTopInset, topOverlayHeight + 30)
        let bottomInset: CGFloat

        if isShowingElevationChart {
            bottomInset = max(isScreenshotShot ? 186 : 228, bottomOverlayHeight + 20)
        } else {
            bottomInset = 24
        }

        return RouteMapFitInsets(top: topInset, bottom: bottomInset)
    }

    var body: some View {
        ZStack(alignment: .top) {
            RouteMapSurface(
                route: route,
                displayMode: .fullScreen,
                routeFitInsets: fullScreenRouteFitInsets,
                activeElevationSample: activeElevationSample,
                lockedElevationSample: lockedElevationSample,
                fitTrigger: fitTrigger,
                onRouteDistanceSelection: { distanceMeters in
                    activeElevationDistanceMeters = distanceMeters
                }
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.bold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)

                        RouteMapSettingsButton()

                        Button {
                            fitTrigger += 1
                        } label: {
                            Image(systemName: "scope")
                                .font(.headline.weight(.bold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recenter route")

                        Spacer(minLength: 0)
                    }

                    if isShowingElevationChart {
                        Text(route.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .frame(maxWidth: 280, alignment: .leading)
                    }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: RouteTopOverlayHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )

                Spacer()
            }
            .onPreferenceChange(RouteTopOverlayHeightPreferenceKey.self) { value in
                topOverlayHeight = value
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 24)

            VStack {
                Spacer()

                if !isShowingElevationChart {
                    HStack {
                        Spacer(minLength: 0)

                        Button(action: onToggleElevationChart) {
                            Image(systemName: "eye")
                                .font(.headline.weight(.bold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show elevation chart")
                    }
                    .padding(.bottom, 44)
                }

                if isShowingElevationChart {
                    RouteElevationChartPanel(
                        route: route,
                        activeDistanceMeters: $activeElevationDistanceMeters,
                        lockedDistanceMeters: $lockedElevationDistanceMeters,
                        panelStyle: .fullScreen,
                        isLoading: isLoadingElevationProfile,
                        unavailableMessage: screenshotPreviewSamples.isEmpty ? elevationProfileStatusMessage : nil,
                        primaryActionTitle: canDownloadRouteDetails ? routeDetailsActionTitle : nil,
                        onPrimaryAction: canDownloadRouteDetails ? onDownloadRouteDetails : nil,
                        onToggleVisibility: onToggleElevationChart,
                        sampleOverride: screenshotPreviewSamples
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: RouteBottomOverlayHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onPreferenceChange(RouteBottomOverlayHeightPreferenceKey.self) { value in
                bottomOverlayHeight = value
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: isShowingElevationChart) { _, isShowing in
            if !isShowing {
                bottomOverlayHeight = 0
            }
        }
    }
}

private struct RouteMapSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    let route: RouteRecord
    let displayMode: RouteMapDisplayMode
    let routeFitInsets: RouteMapFitInsets
    let activeElevationSample: RouteElevationSample?
    let lockedElevationSample: RouteElevationSample?
    let fitTrigger: Int
    var onRouteDistanceSelection: ((Double) -> Void)? = nil

    var body: some View {
        RouteMapPreview(
            route: route,
            displayMode: displayMode,
            routeFitInsets: routeFitInsets,
            activeElevationSample: activeElevationSample,
            lockedElevationSample: lockedElevationSample,
            userInterfaceStyle: colorScheme == .dark ? .dark : .light,
            fitTrigger: fitTrigger,
            onRouteDistanceSelection: onRouteDistanceSelection
        )
    }
}

struct RouteMapPreview: UIViewRepresentable {
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue
    let route: RouteRecord
    let displayMode: RouteMapDisplayMode
    let routeFitInsets: RouteMapFitInsets
    let activeElevationSample: RouteElevationSample?
    let lockedElevationSample: RouteElevationSample?
    let userInterfaceStyle: UIUserInterfaceStyle
    let fitTrigger: Int
    let onRouteDistanceSelection: ((Double) -> Void)?

    init(
        route: RouteRecord,
        displayMode: RouteMapDisplayMode = .embedded,
        routeFitInsets: RouteMapFitInsets = .embedded,
        activeElevationSample: RouteElevationSample? = nil,
        lockedElevationSample: RouteElevationSample? = nil,
        userInterfaceStyle: UIUserInterfaceStyle,
        fitTrigger: Int = 0,
        onRouteDistanceSelection: ((Double) -> Void)? = nil
    ) {
        self.route = route
        self.displayMode = displayMode
        self.routeFitInsets = routeFitInsets
        self.activeElevationSample = activeElevationSample
        self.lockedElevationSample = lockedElevationSample
        self.userInterfaceStyle = userInterfaceStyle
        self.fitTrigger = fitTrigger
        self.onRouteDistanceSelection = onRouteDistanceSelection
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(displayMode: displayMode)
    }

    func makeUIView(context: Context) -> MapView {
        RouteVaultMapboxConfiguration.configure()

        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                mapStyle: appRouteMapStyle.resolvedStyle(for: route, colorScheme: userInterfaceStyle),
                cameraOptions: CameraOptions(
                    center: route.startCoordinate,
                    zoom: displayMode == .fullScreen ? 10 : 9,
                    pitch: appRouteMapPerspective.isThreeDimensional ? appRouteMapPerspective.pitch : 0
                )
            )
        )
        context.coordinator.bind(to: mapView)
        configureMapView(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        configureMapView(mapView)
        let coordinates = route.routeCoordinates
        context.coordinator.onRouteDistanceSelection = onRouteDistanceSelection
        guard !coordinates.isEmpty else {
            return
        }

            context.coordinator.updateRouteMap(
                mapView,
                route: route,
                coordinates: coordinates,
                routeSignature: "\(route.stravaRouteID)|\(route.routeGeometryPolyline)",
                surfaceKind: route.surfaceKind,
                routeMapStyle: appRouteMapStyle,
                userInterfaceStyle: userInterfaceStyle,
                perspective: appRouteMapPerspective,
                routeFitInsets: routeFitInsets,
                fitTrigger: fitTrigger
            )
        context.coordinator.updateHighlightedSamples(
            activeElevationSample: activeElevationSample,
            lockedElevationSample: lockedElevationSample,
            on: mapView
        )
    }

    private var usesTerrainStyle: Bool {
        switch route.sportKind {
        case .trailRun, .hike, .snowshoe:
            return true
        case .run, .walk:
            return route.surfaceKind == .trail
        default:
            return route.surfaceKind == .trail
        }
    }

    private func configureMapView(_ mapView: MapView) {
        mapView.location.options.puckType = .puck2D()

        var ornamentOptions = mapView.ornaments.options
        ornamentOptions.compass.visibility = displayMode.showsCompass ? .adaptive : .hidden
        ornamentOptions.scaleBar.visibility = displayMode == .fullScreen ? .hidden : (displayMode.showsScale ? .adaptive : .hidden)
        mapView.ornaments.options = ornamentOptions

        mapView.gestures.options.pitchEnabled = displayMode.allowsPitch || appRouteMapPerspective.isThreeDimensional
        mapView.gestures.options.rotateEnabled = displayMode.allowsRotate
    }

    final class Coordinator {
        private struct RouteRenderState {
            let coordinates: [CLLocationCoordinate2D]
            let elevationSamples: [RouteElevationSample]
            let routeSignature: String
            let surfaceKind: RouteSurfaceKind?
            let perspective: AppRouteMapPerspective
            let usesStandardDarkReadabilityTuning: Bool
            let routeFitInsets: RouteMapFitInsets
            let fitTrigger: Int
        }

        private struct HighlightState: Equatable {
            let activeElevationSample: RouteElevationSample?
            let lockedElevationSample: RouteElevationSample?
        }

        private let displayMode: RouteMapDisplayMode
        private var cancelables = Set<AnyCancelable>()
        private weak var mapView: MapView?
        private var routeOutlineManager: PolylineAnnotationManager?
        private var routeLineManager: PolylineAnnotationManager?
        private var directionArrowManager: PointAnnotationManager?
        private var markerManager: PointAnnotationManager?
        private var lastRouteRenderSignature: String?
        private var lastRouteCameraSignature: String?
        private var lastStyleKey: String?
        private var lastPerspectivePitch: CGFloat?
        private var currentRouteRenderState: RouteRenderState?
        private var currentHighlightState = HighlightState(activeElevationSample: nil, lockedElevationSample: nil)
        private var preservedCameraOnNextStyleLoad: CameraOptions?
        private var cameraChangeArrowRefreshTask: Task<Void, Never>?
        var onRouteDistanceSelection: ((Double) -> Void)?
        private lazy var activeMarkerImage = markerImage(fill: UIColor(red: 0.95, green: 0.48, blue: 0.26, alpha: 0.96))
        private lazy var lockedMarkerImage = markerImage(fill: UIColor(red: 0.33, green: 0.64, blue: 0.98, alpha: 0.96))

        init(displayMode: RouteMapDisplayMode) {
            self.displayMode = displayMode
        }

        func bind(to mapView: MapView) {
            guard self.mapView !== mapView else {
                return
            }

            cancelables.removeAll()
            self.mapView = mapView

            mapView.mapboxMap.onStyleLoaded.observeNext { [weak self, weak mapView] _ in
                guard let self, let mapView else {
                    return
                }

                RouteMapStyleReadabilityTuning.apply(
                    to: mapView.mapboxMap,
                    usesStandardDarkStyle: self.currentRouteRenderState?.usesStandardDarkReadabilityTuning ?? false
                )
                RouteMapTerrainTuning.apply(
                    to: mapView.mapboxMap,
                    perspective: self.currentRouteRenderState?.perspective ?? .defaultValue
                )
                self.recreateManagers(on: mapView)
                self.reapplyCurrentState(on: mapView)
            }
            .store(in: &cancelables)

            mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
                guard let self else {
                    return
                }

                self.cameraChangeArrowRefreshTask?.cancel()
                self.cameraChangeArrowRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(75))
                    guard let self, !Task.isCancelled else {
                        return
                    }

                    self.refreshDirectionArrowsForCurrentCamera()
                }
            }
            .store(in: &cancelables)
        }

        func updateRouteMap(
            _ mapView: MapView,
            route: RouteRecord,
            coordinates: [CLLocationCoordinate2D],
            routeSignature: String,
            surfaceKind: RouteSurfaceKind?,
            routeMapStyle: AppRouteMapStyle,
            userInterfaceStyle: UIUserInterfaceStyle,
            perspective: AppRouteMapPerspective,
            routeFitInsets: RouteMapFitInsets,
            fitTrigger: Int
        ) {
            currentRouteRenderState = RouteRenderState(
                coordinates: coordinates,
                elevationSamples: route.elevationProfile,
                routeSignature: routeSignature,
                surfaceKind: surfaceKind,
                perspective: perspective,
                usesStandardDarkReadabilityTuning: routeMapStyle.usesStandardDarkReadabilityTuning(
                    for: route,
                    colorScheme: userInterfaceStyle
                ),
                routeFitInsets: routeFitInsets,
                fitTrigger: fitTrigger
            )
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: perspective
            )

            let styleKey = "\(routeMapStyle.rawValue)-\(userInterfaceStyle.rawValue)-\(route.prefersOutdoorsMapStyle)"
            if styleKey != lastStyleKey {
                let shouldPreserveExistingCamera = lastStyleKey != nil
                lastStyleKey = styleKey
                preservedCameraOnNextStyleLoad = shouldPreserveExistingCamera ? currentCameraOptions(from: mapView) : nil
                mapView.mapboxMap.mapStyle = routeMapStyle.resolvedStyle(
                    for: route,
                    colorScheme: userInterfaceStyle
                )
                recreateManagers(on: mapView)
                lastRouteRenderSignature = nil
            }

            let renderSignature = "\(routeSignature)|\(surfaceKind?.rawValue ?? "none")"
            if renderSignature != lastRouteRenderSignature {
                ensureManagers(on: mapView)
                renderRouteAnnotations(
                    coordinates: coordinates,
                    surfaceKind: surfaceKind
                )
                lastRouteRenderSignature = renderSignature
            }

            let cameraSignature = "\(routeSignature)|\(perspective.rawValue)|\(fitTrigger)"
            let cameraSignatureWithInset = "\(cameraSignature)|\(routeFitInsets.top.rounded())|\(routeFitInsets.bottom.rounded())"
            if cameraSignatureWithInset != lastRouteCameraSignature || lastPerspectivePitch != perspective.pitch {
                lastRouteCameraSignature = cameraSignatureWithInset
                lastPerspectivePitch = perspective.pitch
                fitCamera(on: mapView, coordinates: coordinates, perspective: perspective, routeFitInsets: routeFitInsets)
            }
        }

        func updateHighlightedSamples(
            activeElevationSample: RouteElevationSample?,
            lockedElevationSample: RouteElevationSample?,
            on mapView: MapView
        ) {
            let nextHighlightState = HighlightState(
                activeElevationSample: activeElevationSample,
                lockedElevationSample: lockedElevationSample
            )

            guard nextHighlightState != currentHighlightState else {
                return
            }

            currentHighlightState = nextHighlightState

            ensureManagers(on: mapView)
            renderHighlightedSamples(
                activeElevationSample: activeElevationSample,
                lockedElevationSample: lockedElevationSample
            )
        }

        private func renderHighlightedSamples(
            activeElevationSample: RouteElevationSample?,
            lockedElevationSample: RouteElevationSample?
        ) {
            var annotations: [PointAnnotation] = []

            if let lockedElevationSample {
                var lockedMarker = PointAnnotation(coordinate: lockedElevationSample.coordinate)
                lockedMarker.image = .init(image: lockedMarkerImage, name: "locked-elevation-marker")
                annotations.append(lockedMarker)
            }

            if let activeElevationSample {
                var activeMarker = PointAnnotation(coordinate: activeElevationSample.coordinate)
                activeMarker.image = .init(image: activeMarkerImage, name: "active-elevation-marker")
                annotations.append(activeMarker)
            }

            markerManager?.annotations = annotations
        }

        private func renderRouteAnnotations(
            coordinates: [CLLocationCoordinate2D],
            surfaceKind: RouteSurfaceKind?
        ) {
            var outlinePolyline = PolylineAnnotation(lineCoordinates: coordinates)
            outlinePolyline.lineColor = StyleColor(RouteMapLineStyle.outlineColor)
            outlinePolyline.lineWidth = RouteMapLineStyle.outlineWidth

            var routePolyline = PolylineAnnotation(lineCoordinates: coordinates)
            routePolyline.lineColor = StyleColor(RouteMapLineStyle.fillColor)
            routePolyline.lineWidth = RouteMapLineStyle.fillWidth
            routePolyline.tapHandler = { [weak self] context in
                self?.handleRouteTap(context) ?? false
            }

            routeOutlineManager?.lineDasharray = nil
            routeOutlineManager?.annotations = [outlinePolyline]

            routeLineManager?.lineDasharray = surfaceKind == .paved ? nil : RouteMapLineStyle.unpavedDashPattern
            routeLineManager?.annotations = [routePolyline]
            directionArrowManager?.annotations = RouteDirectionArrowRenderer.annotations(
                for: coordinates,
                imageNamePrefix: "route-detail-direction-arrow-\(displayMode == .fullScreen ? "full" : "embedded")",
                zoomLevel: mapView.map { CGFloat($0.mapboxMap.cameraState.zoom) },
                visibleBounds: mapView.map { $0.mapboxMap.coordinateBounds(for: $0.bounds) }
            )
        }

        private func reapplyCurrentState(on mapView: MapView) {
            ensureManagers(on: mapView)

            if let currentRouteRenderState {
                renderRouteAnnotations(
                    coordinates: currentRouteRenderState.coordinates,
                    surfaceKind: currentRouteRenderState.surfaceKind
                )
                if let preservedCameraOnNextStyleLoad {
                    mapView.camera.ease(to: preservedCameraOnNextStyleLoad, duration: 0)
                    self.preservedCameraOnNextStyleLoad = nil
                } else {
                    fitCamera(
                        on: mapView,
                        coordinates: currentRouteRenderState.coordinates,
                        perspective: currentRouteRenderState.perspective,
                        routeFitInsets: currentRouteRenderState.routeFitInsets
                    )
                }
            }

            renderHighlightedSamples(
                activeElevationSample: currentHighlightState.activeElevationSample,
                lockedElevationSample: currentHighlightState.lockedElevationSample
            )
        }

        @MainActor
        private func refreshDirectionArrowsForCurrentCamera() {
            guard let currentRouteRenderState else {
                return
            }

            renderRouteAnnotations(
                coordinates: currentRouteRenderState.coordinates,
                surfaceKind: currentRouteRenderState.surfaceKind
            )
        }

        private func recreateManagers(on mapView: MapView) {
            let routeLineManagerID = "route-map-lines-\(displayMode == .fullScreen ? "full" : "embedded")"
            let routeOutlineManagerID = "route-map-lines-outline-\(displayMode == .fullScreen ? "full" : "embedded")"
            let directionArrowManagerID = "route-map-direction-arrows-\(displayMode == .fullScreen ? "full" : "embedded")"
            let markerManagerID = "route-map-markers-\(displayMode == .fullScreen ? "full" : "embedded")"

            mapView.annotations.removeAnnotationManager(withId: routeOutlineManagerID)
            mapView.annotations.removeAnnotationManager(withId: routeLineManagerID)
            mapView.annotations.removeAnnotationManager(withId: directionArrowManagerID)
            mapView.annotations.removeAnnotationManager(withId: markerManagerID)

            routeOutlineManager = mapView.annotations.makePolylineAnnotationManager(id: routeOutlineManagerID)
            routeLineManager = mapView.annotations.makePolylineAnnotationManager(id: routeLineManagerID)
            directionArrowManager = mapView.annotations.makePointAnnotationManager(id: directionArrowManagerID)
            markerManager = mapView.annotations.makePointAnnotationManager(id: markerManagerID)
        }

        private func ensureManagers(on mapView: MapView) {
            if routeOutlineManager == nil ||
                routeLineManager == nil ||
                directionArrowManager == nil ||
                markerManager == nil {
                recreateManagers(on: mapView)
            }
        }

        private func fitCamera(
            on mapView: MapView,
            coordinates: [CLLocationCoordinate2D],
            perspective: AppRouteMapPerspective,
            routeFitInsets: RouteMapFitInsets
        ) {
            let coordinatesPadding = displayMode.edgePadding(fitInsets: routeFitInsets)
            let cameraOptions: CameraOptions

            do {
                cameraOptions = try mapView.mapboxMap.camera(
                    for: coordinates,
                    camera: CameraOptions(
                        bearing: 0,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    coordinatesPadding: coordinatesPadding,
                    maxZoom: displayMode.maximumRouteFitZoom,
                    offset: nil
                )
            } catch {
                if let bounds = RouteMapboxGeometry.coordinateBounds(
                    for: coordinates,
                    minimumMeters: displayMode.minimumMapDimension,
                    paddingFactor: displayMode.paddingFactor
                ) {
                    do {
                        let fallbackCamera = try mapView.mapboxMap.camera(
                            for: [bounds.southwest, bounds.southeast, bounds.northeast, bounds.northwest],
                            camera: CameraOptions(
                                bearing: 0,
                                pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                            ),
                            coordinatesPadding: coordinatesPadding,
                            maxZoom: displayMode.maximumRouteFitZoom,
                            offset: nil
                        )
                        mapView.camera.ease(
                            to: fallbackCamera,
                            duration: 0
                        )
                    } catch {
                        mapView.camera.ease(
                            to: CameraOptions(
                                center: coordinates.first,
                                zoom: min(displayMode.maximumRouteFitZoom, 11),
                                pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                            ),
                            duration: 0
                        )
                    }
                }
                return
            }

            mapView.camera.ease(to: cameraOptions, duration: 0)
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

        private func handleRouteTap(_ context: InteractionContext) -> Bool {
            guard let distanceMeters = nearestDistanceForRouteTap(at: context.coordinate) else {
                return false
            }

            DispatchQueue.main.async { [onRouteDistanceSelection] in
                onRouteDistanceSelection?(distanceMeters)
            }
            return true
        }

        private func nearestDistanceForRouteTap(at coordinate: CLLocationCoordinate2D) -> Double? {
            guard let elevationSamples = currentRouteRenderState?.elevationSamples,
                  !elevationSamples.isEmpty else {
                return nil
            }

            return elevationSamples.min(by: {
                $0.coordinate.routeDistance(to: coordinate) < $1.coordinate.routeDistance(to: coordinate)
            })?.distanceMeters
        }

        private func markerImage(fill: UIColor) -> UIImage {
            let size = CGSize(width: 18, height: 18)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 2),
                    blur: 6,
                    color: UIColor.black.withAlphaComponent(0.22).cgColor
                )
                context.cgContext.setFillColor(fill.cgColor)
                context.cgContext.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
                context.cgContext.setStrokeColor(UIColor.white.cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
            }
        }
    }

    private var appRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private var appRouteMapPerspective: AppRouteMapPerspective {
        AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? AppRouteMapPerspective.defaultValue
    }
}

private struct RouteOfflineDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: RouteRecord
    let offlineStatus: RouteOfflineAssetStatus
    @Binding var selection: RouteOfflineDownloadSelection
    let isDownloading: Bool
    let downloadProgress: RouteOfflineDownloadProgress?
    let onDownload: () -> Void

    var body: some View {
        List {
            if offlineStatus.hasAnyAssets {
                Section("Currently Saved") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(offlineStatus.summaryText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        FlexibleOfflineStatusPills(labels: offlineStatus.componentLabels)

                        HStack(spacing: 12) {
                            Label(currentSavedSizeText, systemImage: "externaldrive")
                            if let downloadedAt = offlineStatus.downloadedAt {
                                Label("Updated \(RouteDisplayFormatter.calendarDate(downloadedAt))", systemImage: "clock")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let downloadProgress {
                Section("Progress") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(downloadProgress.message)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            if let percentageText = downloadProgress.percentageText {
                                Text(percentageText)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let fractionCompleted = downloadProgress.fractionCompleted {
                            ProgressView(value: fractionCompleted, total: 1)
                            Text("Overall progress")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Route Data") {
                RouteOfflineToggleRow(
                    title: "GPX",
                    subtitle: selection.normalizedMapStyles.isEmpty
                        ? "Route geometry and elevation data"
                        : "Required because one or more offline map styles are selected",
                    isOn: Binding(
                        get: { selection.includesGPX || !selection.normalizedMapStyles.isEmpty },
                        set: { newValue in
                            if selection.normalizedMapStyles.isEmpty {
                                selection.includesGPX = newValue
                            }
                        }
                    ),
                    sizeText: byteCountText(Self.estimatedGPXBytes(for: route)),
                    statusText: offlineStatus.hasGPX ? "Saved" : (selection.normalizedMapStyles.isEmpty ? "Needed" : "Required"),
                    isDisabled: !selection.normalizedMapStyles.isEmpty
                )
            }

            Section("Map Styles") {
                ForEach(AppRouteMapStyle.allCases) { mapStyle in
                    RouteOfflineToggleRow(
                        title: mapStyle.title,
                        subtitle: mapStyle == .dark ? "Standard tiles with dark styling" : nil,
                        isOn: Binding(
                            get: { selection.normalizedMapStyles.contains(mapStyle) },
                            set: { isSelected in
                                var updated = selection.normalizedMapStyles
                                if isSelected {
                                    updated.append(mapStyle)
                                    selection.includesGPX = true
                                } else {
                                    updated.removeAll { $0 == mapStyle }
                                    if updated.isEmpty {
                                        selection.includesTerrain = false
                                    }
                                }
                                selection.mapStyles = updated
                            }
                        ),
                        sizeText: byteCountText(Self.estimatedMapBytes(for: route, mapStyle: mapStyle)),
                        statusText: offlineStatus.mapStyles.contains(mapStyle) ? "Saved" : "Not Saved"
                    )
                }
            }

            Section("Extras") {
                RouteOfflineToggleRow(
                    title: "3D Terrain",
                    subtitle: "Offline terrain shading for 3D mode",
                    isOn: Binding(
                        get: { selection.includesTerrain },
                        set: { newValue in
                            selection.includesTerrain = newValue && !selection.normalizedMapStyles.isEmpty
                        }
                    ),
                    sizeText: byteCountText(Self.estimatedTerrainBytes(for: route)),
                    statusText: offlineStatus.includesTerrain ? "Saved" : "Not Saved",
                    isDisabled: selection.normalizedMapStyles.isEmpty
                )
            }

            Section {
                HStack {
                    Text("Selected Download Size")
                    Spacer()
                    Text(byteCountText(totalEstimatedBytes))
                        .foregroundStyle(.secondary)
                }
            }
        }

        .navigationTitle("Offline Download")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("route-offline-download-screen-\(route.stravaRouteID)")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("route-offline-download-cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(downloadProgress?.buttonLabel ?? (isDownloading ? "Preparing download" : "Download")) {
                    onDownload()
                }
                .accessibilityIdentifier("route-offline-download-confirm")
                .disabled(isDownloading || !selection.hasDownloadableSelection)
            }
        }
    }

    private var totalEstimatedBytes: Int64 {
        var total = selection.includesGPX ? Self.estimatedGPXBytes(for: route) : 0
        let uniqueStyleKeys = Set(selection.normalizedMapStyles.map { $0.resolvedStyleURI(for: route).rawValue })
        for styleKey in uniqueStyleKeys {
            switch styleKey {
            case StyleURI.outdoors.rawValue:
                total += Self.estimatedMapBytes(for: route, mapStyle: .outdoors)
            case StyleURI.satellite.rawValue:
                total += Self.estimatedMapBytes(for: route, mapStyle: .satellite)
            case StyleURI.satelliteStreets.rawValue:
                total += Self.estimatedMapBytes(for: route, mapStyle: .hybrid)
            default:
                total += Self.estimatedMapBytes(for: route, mapStyle: .standard)
            }
        }
        if selection.includesTerrain {
            total += Self.estimatedTerrainBytes(for: route)
        }
        return total
    }

    private func byteCountText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private var currentSavedSizeText: String {
        guard offlineStatus.totalBytes > 0 else {
            return offlineStatus.hasAnyAssets ? "Needs refresh" : "Not saved"
        }

        return byteCountText(offlineStatus.totalBytes)
    }

    private static func estimatedGPXBytes(for route: RouteRecord) -> Int64 {
        max(36_000, Int64(route.routeCoordinates.count * 56) + 24_000)
    }

    private static func estimatedMapBytes(for route: RouteRecord, mapStyle: AppRouteMapStyle) -> Int64 {
        let distanceMiles = route.distanceMeters * 0.000621371
        let distanceFactor = max(0.8, min(3.2, distanceMiles / 6.0))
        let baseMegabytes: Double
        switch mapStyle {
        case .outdoors:
            baseMegabytes = 18
        case .standard, .dark:
            baseMegabytes = 16
        case .hybrid:
            baseMegabytes = 30
        case .satellite:
            baseMegabytes = 36
        }
        return Int64(baseMegabytes * distanceFactor * 1_048_576)
    }

    private static func estimatedTerrainBytes(for route: RouteRecord) -> Int64 {
        let distanceMiles = route.distanceMeters * 0.000621371
        let distanceFactor = max(0.75, min(2.8, distanceMiles / 7.0))
        return Int64(20 * distanceFactor * 1_048_576)
    }
}

private struct RouteOfflineToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    let sizeText: String
    let statusText: String?
    var isDisabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    if let statusText {
                        Text(statusText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(statusText == "Saved" ? Color.green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    Text(sizeText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isDisabled)
    }
}

private struct FlexibleOfflineStatusPills: View {
    let labels: [String]

    var body: some View {
        if labels.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private extension CLLocationCoordinate2D {
    func routeDistance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}
