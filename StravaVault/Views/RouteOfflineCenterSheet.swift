import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RouteOfflineCenterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppMeasurementSystem.storageKey) private var appMeasurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue

    let visibleRoutes: [RouteRecord]

    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var selectedRoute: RouteRecord?
    @State private var processingCompletedCount = 0
    @State private var processingTotalCount = 0
    @State private var processingRouteID: Int?
    @State private var processingRouteName: String?
    @State private var processingProgress: RouteOfflineDownloadProgress?

    private let offlineAssetService = RouteOfflineAssetService()
    private let offlineDownloadCoordinator = RouteOfflineDownloadCoordinator()
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var visibleRouteEntries: [(route: RouteRecord, status: RouteOfflineAssetStatus)] {
        visibleRoutes.map { route in
            (route: route, status: offlineAssetService.offlineStatus(for: route))
        }
    }

    private var savedRoutes: [RouteRecord] {
        visibleRouteEntries
            .filter { $0.status.hasConcreteAssets }
            .map(\.route)
    }

    private var routesNeedingDownload: [RouteRecord] {
        visibleRouteEntries
            .filter { !$0.status.hasConcreteAssets }
            .map(\.route)
    }

    private var routesNeedingRefreshCount: Int {
        visibleRouteEntries.filter { $0.status.hasAnyAssets && !$0.status.hasConcreteAssets }.count
    }

    private var removableRoutes: [RouteRecord] {
        visibleRouteEntries
            .filter { $0.status.hasAnyAssets }
            .map(\.route)
    }

    private var totalOfflineBytes: Int64 {
        visibleRouteEntries.reduce(into: Int64(0)) { total, entry in
            total += entry.status.totalBytes
        }
    }

    private var processingFractionCompleted: Double {
        guard processingTotalCount > 0 else {
            return 0
        }

        let inFlightFraction = max(0, min(1, processingProgress?.fractionCompleted ?? 0))
        return min(1, (Double(processingCompletedCount) + inFlightFraction) / Double(processingTotalCount))
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    BannerView(message: errorMessage, tone: .error)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            if let statusMessage {
                Section {
                    BannerView(message: statusMessage, tone: .success)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section("Summary") {
                LabeledContent("Routes Matching Filters", value: "\(visibleRoutes.count)")
                LabeledContent("Routes With Offline Files", value: "\(savedRoutes.count)")
                if routesNeedingRefreshCount > 0 {
                    LabeledContent("Needs Refresh", value: "\(routesNeedingRefreshCount)")
                }
                LabeledContent("Cached Storage", value: byteCountFormatter.string(fromByteCount: totalOfflineBytes))
            }

            Section("Batch Actions") {
                Button {
                    Task { await cacheRoutes(routesNeedingDownload) }
                } label: {
                    Label("Download Missing Default Offline Files", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("offline-center-download-missing")
                .disabled(isProcessing || routesNeedingDownload.isEmpty)

                Button {
                    Task { await cacheRoutes(savedRoutes) }
                } label: {
                    Label("Refresh Saved Offline Files", systemImage: "arrow.clockwise.circle")
                }
                .accessibilityIdentifier("offline-center-refresh-saved")
                .disabled(isProcessing || savedRoutes.isEmpty)

                Button(role: .destructive) {
                    removeOfflineAssets(for: removableRoutes)
                } label: {
                    Label("Remove Saved Offline Files", systemImage: "trash")
                }
                .accessibilityIdentifier("offline-center-remove-saved")
                .disabled(isProcessing || removableRoutes.isEmpty)

                if isProcessing {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(processingRouteName.map { "Updating \($0)" } ?? "Updating offline files")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)

                            Text("\(processingCompletedCount)/\(max(processingTotalCount, 1))")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            if let percentageText = processingProgress?.percentageText {
                                Text(percentageText)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ProgressView(value: processingFractionCompleted, total: 1)

                        Text(processingProgress?.message ?? "Route-by-route progress for the current batch action")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Batch downloads save the default bundle: GPX + Outdoors map. Open a route to choose different map styles or terrain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(visibleRoutes.isEmpty ? "Routes Matching Filters" : "Routes Matching Filters (\(visibleRoutes.count))") {
                if visibleRoutes.isEmpty {
                    ContentUnavailableView(
                        "No Routes Match Current Filters",
                        systemImage: "tray",
                        description: Text("Adjust your filters or sync more routes to manage them offline.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(visibleRouteEntries, id: \.route.stravaRouteID) { entry in
                        let route = entry.route
                        RouteOfflineRow(
                            route: route,
                            offlineStatus: entry.status,
                            byteText: byteCountFormatter.string(fromByteCount: entry.status.totalBytes),
                            gpxURL: entry.status.hasGPX ? offlineAssetService.gpxURL(for: route) : nil,
                            isActionDisabled: isProcessing,
                            downloadProgress: processingRouteID == route.stravaRouteID ? processingProgress : nil,
                            onDownload: {
                                Task { await cacheRoutes([route]) }
                            },
                            onRemove: {
                                removeOfflineAssets(for: [route])
                            },
                            onOpen: {
                                selectedRoute = route
                            }
                        )
                    }
                }
            }
        }
        .id("offline-center-\(appMeasurementSystemRawValue)")
        .navigationTitle("Offline Center")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("offline-center-screen")
        .sheet(item: $selectedRoute) { route in
            NavigationStack {
                RouteEditorSheet(
                    route: route,
                    onDelete: { routeToDelete in
                        modelContext.delete(routeToDelete)
                        try? modelContext.save()
                        selectedRoute = nil
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") {
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    @MainActor
    private func cacheRoutes(_ routes: [RouteRecord]) async {
        guard !routes.isEmpty else {
            statusMessage = "No routes were selected for offline download."
            return
        }

        guard !isProcessing else {
            statusMessage = processingRouteName.map {
                "Offline files are already updating for \($0)."
            } ?? "Offline files are already updating."
            return
        }

        isProcessing = true
        statusMessage = nil
        errorMessage = nil
        processingCompletedCount = 0
        processingTotalCount = routes.count
        processingRouteID = routes.first?.stravaRouteID
        processingRouteName = routes.first?.name
        processingProgress = nil

        var completed = 0
        var failures: [String] = []

        for route in routes {
            processingRouteID = route.stravaRouteID
            processingRouteName = route.name
            processingProgress = nil

            do {
                let storedAssets = try await offlineDownloadCoordinator.storeOfflineBundle(
                    for: route,
                    progress: { progress in
                        Task { @MainActor in
                            processingProgress = progress
                        }
                    }
                )
                route.offlineGPXRelativePath = storedAssets.gpxRelativePath
                route.offlineMapSnapshotRelativePath = storedAssets.mapSnapshotRelativePath
                route.offlineDownloadedAt = storedAssets.downloadedAt
                completed += 1
            } catch {
                failures.append("\(route.name): \(error.localizedDescription)")
            }

            processingCompletedCount += 1
            processingProgress = nil
        }

        try? modelContext.save()

        if completed > 0 {
            statusMessage = completed == 1
                ? "Saved offline files for 1 route."
                : "Saved offline files for \(completed) routes."
        }

        if !failures.isEmpty {
            errorMessage = failures.count == 1
                ? failures[0]
                : "\(failures.count) routes could not be saved offline. \(failures[0])"
        }

        isProcessing = false
        processingCompletedCount = 0
        processingTotalCount = 0
        processingRouteID = nil
        processingRouteName = nil
        processingProgress = nil
    }

    private func removeOfflineAssets(for routes: [RouteRecord]) {
        guard !routes.isEmpty else {
            return
        }

        guard !isProcessing else {
            statusMessage = "Wait for the current offline update to finish before removing files."
            return
        }

        var removedCount = 0

        for route in routes where offlineAssetService.offlineStatus(for: route).hasAnyAssets {
            do {
                try offlineAssetService.removeOfflineAssets(for: route)
                route.offlineGPXRelativePath = nil
                route.offlineMapSnapshotRelativePath = nil
                route.offlineDownloadedAt = nil
                removedCount += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        try? modelContext.save()

        if removedCount > 0 {
            statusMessage = removedCount == 1
                ? "Removed offline files from 1 route."
                : "Removed offline files from \(removedCount) routes."
        }
    }
}

private struct RouteOfflineRow: View {
    let route: RouteRecord
    let offlineStatus: RouteOfflineAssetStatus
    let byteText: String
    let gpxURL: URL?
    let isActionDisabled: Bool
    let downloadProgress: RouteOfflineDownloadProgress?
    let onDownload: () -> Void
    let onRemove: () -> Void
    let onOpen: () -> Void

    private var offlineStatusLabel: String {
        if offlineStatus.hasConcreteAssets {
            return "Saved"
        }

        if offlineStatus.hasAnyAssets {
            return "Needs Refresh"
        }

        return "Not Saved"
    }

    private var offlineStatusColor: Color {
        if offlineStatus.hasConcreteAssets {
            return .green
        }

        if offlineStatus.hasAnyAssets {
            return .orange
        }

        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
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

                Text(offlineStatusLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(offlineStatusColor)
            }

            Text(offlineStatus.summaryText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(offlineStatus.hasConcreteAssets ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if offlineStatus.hasConcreteAssets {
                RouteOfflineAssetPills(labels: offlineStatus.componentLabels)
            }

            if let downloadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(downloadProgress.message)
                            .font(.caption.weight(.semibold))
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
                    } else {
                        ProgressView()
                    }
                }
            }

            HStack(spacing: 12) {
                Label(RouteDisplayFormatter.distance(route.distanceMeters), systemImage: "ruler")
                Label(offlineStorageText, systemImage: "externaldrive")
                if let downloadedAt = offlineStatus.downloadedAt {
                    Label("Updated \(RouteDisplayFormatter.calendarDate(downloadedAt))", systemImage: "clock")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if offlineStatus.hasConcreteAssets {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Refresh saved offline route")
                    .accessibilityIdentifier("offline-row-refresh-\(route.stravaRouteID)")
                    .disabled(isActionDisabled)
                } else {
                    Button(downloadProgress == nil ? "Download" : "Downloading…", action: onDownload)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("offline-row-download-\(route.stravaRouteID)")
                        .disabled(isActionDisabled)
                }

                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("offline-row-open-\(route.stravaRouteID)")

                if offlineStatus.hasAnyAssets {
                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("offline-row-remove-\(route.stravaRouteID)")
                        .disabled(isActionDisabled)
                }

                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Share GPX")
                    .accessibilityIdentifier("offline-row-share-gpx-\(route.stravaRouteID)")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("offline-row-\(route.stravaRouteID)")
    }

    private var offlineStorageText: String {
        guard offlineStatus.totalBytes > 0 else {
            return offlineStatus.hasAnyAssets ? "Needs refresh" : "Not saved"
        }

        return byteText
    }
}

private struct RouteOfflineAssetPills: View {
    let labels: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
    }
}

