import Foundation
import SwiftData
import SwiftUI
import UIKit

struct DataExportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\ActivityRecord.startDate, order: .reverse)]) private var activities: [ActivityRecord]
    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var routes: [RouteRecord]
    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var lists: [RouteList]

    @State private var selectedDataset: DataExportDataset = .activities
    @State private var selectedFormat: DataExportFormat = .csv
    @State private var includeLocalActivities = false
    @State private var isPreparingExport = false
    @State private var preparedExport: PreparedDataExport?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var filteredActivities: [ActivityRecord] {
        includeLocalActivities ? activities : activities.filter { $0.sourceKind == .strava }
    }

    private var availableFormats: [DataExportFormat] {
        selectedDataset.supportedFormats
    }

    private var usesClipboardExport: Bool {
        selectedDataset == .lists && selectedFormat == .markdown
    }

    private var exportableItemCount: Int {
        switch selectedDataset {
        case .activities:
            return filteredActivities.count
        case .routes:
            return routes.count
        case .lists:
            return lists.count
        case .allData:
            return filteredActivities.count + routes.count + lists.count
        }
    }

    private var helperCopy: String {
        switch selectedDataset {
        case .activities:
            return "Export your activity history, metrics, location fields, and Strava-linked identifiers as a reusable file."
        case .routes:
            return "Export the route library with sport, surface, offline state, and list membership."
        case .lists:
            return "Export list metadata, descriptions, sharing flags, or copy bulleted route text with visible Strava links."
        case .allData:
            return "Export the full app data bundle in one JSON file for backup or analysis."
        }
    }

    private var scopeCopy: String {
        if selectedDataset == .activities || selectedDataset == .allData {
            return includeLocalActivities
                ? "Including Strava-synced activities plus local imports/uploads."
                : "Including only Strava-synced activities."
        }

        return "Includes all current local app data for this dataset."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage = errorMessage?.trimmed.nilIfEmpty {
                    DataExportBanner(message: errorMessage, tone: .error)
                }

                if let statusMessage = statusMessage?.trimmed.nilIfEmpty {
                    DataExportBanner(message: statusMessage, tone: .success)
                }

                headerCard
                datasetCard
                formatCard

                if selectedDataset == .activities || selectedDataset == .allData {
                    scopeCard
                }

                summaryCard
                exportActionCard
            }
            .padding(20)
        }
        .accessibilityIdentifier("export-data-screen")
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Export Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", action: dismiss.callAsFunction)
                    .fontWeight(.semibold)
            }
        }
        .sheet(item: $preparedExport, onDismiss: cleanupPreparedExport) { export in
            DataExportShareSheet(items: [export.url])
                .ignoresSafeArea()
        }
        .onChange(of: selectedDataset) { _, newDataset in
            if !newDataset.supportedFormats.contains(selectedFormat) {
                selectedFormat = newDataset.supportedFormats.first ?? .json
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Take your Strava and Terigo history with you.")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text(helperCopy)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var datasetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dataset")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            VStack(spacing: 10) {
                ForEach(DataExportDataset.allCases) { dataset in
                    Button {
                        selectedDataset = dataset
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: dataset.symbolName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(selectedDataset == dataset ? Color.black : .white)
                                .frame(width: 26, height: 26)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(dataset.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selectedDataset == dataset ? Color.black : .white)

                                Text(dataset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(selectedDataset == dataset ? Color.black.opacity(0.7) : .secondary)
                            }

                            Spacer(minLength: 0)

                            if selectedDataset == dataset {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.black.opacity(0.75))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            selectedDataset == dataset
                                ? Color(red: 1.0, green: 0.67, blue: 0.48)
                                : Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Format")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                ForEach(availableFormats) { format in
                    Button {
                        selectedFormat = format
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: format.symbolName)
                                .font(.caption.weight(.semibold))
                            Text(format.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(selectedFormat == format ? Color.black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            selectedFormat == format
                                ? Color(red: 1.0, green: 0.67, blue: 0.48)
                                : Color.white.opacity(0.05),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(selectedFormat.description(for: selectedDataset))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scope")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Toggle(isOn: $includeLocalActivities) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include local imports and uploads")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("Turn this off to export only Strava-synced activities.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Color(red: 1.0, green: 0.67, blue: 0.48))

            Text(scopeCopy)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 12) {
                DataExportMetric(title: "Records", value: RouteDisplayFormatter.compactCount(exportableItemCount))
                DataExportMetric(title: "Format", value: selectedFormat.fileExtension.uppercased())
                DataExportMetric(title: usesClipboardExport ? "Output" : "File", value: usesClipboardExport ? "Clipboard" : suggestedFilename)
            }

            Text(previewDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var exportActionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await prepareExport() }
            } label: {
                HStack(spacing: 10) {
                    if isPreparingExport {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: usesClipboardExport ? "doc.on.clipboard" : "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                    }

                    Text(isPreparingExport ? "Preparing Export…" : (usesClipboardExport ? "Copy \(selectedFormat.title)" : "Export \(selectedDataset.title)"))
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    exportableItemCount > 0 ? Color(red: 1.0, green: 0.67, blue: 0.48) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(exportableItemCount == 0 || isPreparingExport)

            if exportableItemCount == 0 {
                Text("There’s nothing in this dataset to export yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if usesClipboardExport {
                Text("Terigo will copy a plain-text bulleted list with visible Strava links to the clipboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Terigo will generate a real \(selectedFormat.title) file and open the system share sheet so you can save it to Files, AirDrop it, or send it anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var suggestedFilename: String {
        let stamp = ExportDateFormatter.filenameStamp(from: .now)
        return "route-vault-\(selectedDataset.fileStem)-\(stamp).\(selectedFormat.fileExtension)"
    }

    private var previewDescription: String {
        switch selectedDataset {
        case .activities:
            return "\(RouteDisplayFormatter.compactCount(filteredActivities.count)) activities ready as \(selectedFormat.title)."
        case .routes:
            return "\(RouteDisplayFormatter.compactCount(routes.count)) routes from the current library will be exported."
        case .lists:
            return usesClipboardExport
                ? "\(RouteDisplayFormatter.compactCount(lists.count)) lists will be copied as bulleted text with visible Strava links."
                : "\(RouteDisplayFormatter.compactCount(lists.count)) lists with descriptions and membership summaries will be exported."
        case .allData:
            return "One JSON backup with \(RouteDisplayFormatter.compactCount(filteredActivities.count)) activities, \(RouteDisplayFormatter.compactCount(routes.count)) routes, and \(RouteDisplayFormatter.compactCount(lists.count)) lists."
        }
    }

    @MainActor
    private func prepareExport() async {
        guard !isPreparingExport else {
            return
        }

        isPreparingExport = true
        errorMessage = nil
        statusMessage = nil

        if usesClipboardExport {
            UIPasteboard.general.string = String(decoding: buildListsMarkdownExport(), as: UTF8.self)
            statusMessage = "Copied bulleted list text for \(RouteDisplayFormatter.compactCount(lists.count)) lists to the clipboard."
            isPreparingExport = false
            return
        }

        do {
            let export = try buildExport()
            preparedExport = export
            statusMessage = "Prepared \(export.recordCount) \(selectedDataset.recordNoun) as \(selectedFormat.title)."
        } catch {
            errorMessage = error.localizedDescription
        }

        isPreparingExport = false
    }

    private func buildExport() throws -> PreparedDataExport {
        let exportData: Data
        let recordCount: Int

        switch selectedDataset {
        case .activities:
            let records = filteredActivities.map(ActivityExportRecord.init)
            exportData = try encode(records)
            recordCount = records.count
        case .routes:
            let records = routes.map(RouteExportRecord.init)
            exportData = try encode(records)
            recordCount = records.count
        case .lists:
            if selectedFormat == .markdown {
                exportData = buildListsMarkdownExport()
                recordCount = lists.count
            } else {
                let records = lists.map { list in
                    ListExportRecord(list: list, memberRoutes: memberRoutes(for: list))
                }
                exportData = try encode(records)
                recordCount = records.count
            }
        case .allData:
            let bundle = FullDataExportBundle(
                exportedAt: ExportDateFormatter.isoString(from: .now),
                activities: filteredActivities.map(ActivityExportRecord.init),
                routes: routes.map(RouteExportRecord.init),
                lists: lists.map { list in
                    ListExportRecord(list: list, memberRoutes: memberRoutes(for: list))
                }
            )
            exportData = try encode(bundle)
            recordCount = bundle.activities.count + bundle.routes.count + bundle.lists.count
        }

        let outputURL = try writeExportFile(data: exportData, filename: suggestedFilename)
        return PreparedDataExport(url: outputURL, recordCount: recordCount)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        switch selectedFormat {
        case .csv:
            if let rows = value as? [ActivityExportRecord] {
                return DataExportCSVBuilder.encode(rows)
            }
            if let rows = value as? [RouteExportRecord] {
                return DataExportCSVBuilder.encode(rows)
            }
            if let rows = value as? [ListExportRecord] {
                return DataExportCSVBuilder.encode(rows)
            }
            throw DataExportError.unsupportedFormat
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        case .markdown:
            throw DataExportError.unsupportedFormat
        }
    }

    private func buildListsMarkdownExport() -> Data {
        let markdown = ListMarkdownExportBuilder.build(
            generatedAt: .now,
            lists: lists,
            memberRoutesProvider: { self.memberRoutes(for: $0) }
        )
        return Data(markdown.utf8)
    }

    private func writeExportFile(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RouteVaultExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let outputURL = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func cleanupPreparedExport() {
        guard let preparedExport else {
            return
        }

        try? FileManager.default.removeItem(at: preparedExport.url)
        self.preparedExport = nil
    }

    private func memberRoutes(for list: RouteList) -> [RouteRecord] {
        let listToken = list.normalizedName
        return routes
            .filter { route in
                route.listNames.contains(where: { $0.routeLabelIdentifier == listToken })
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
    }
}

private enum DataExportDataset: String, CaseIterable, Identifiable {
    case activities
    case routes
    case lists
    case allData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activities: return "Activities"
        case .routes: return "Routes"
        case .lists: return "Lists"
        case .allData: return "All Data"
        }
    }

    var subtitle: String {
        switch self {
        case .activities: return "Past activity history and metrics"
        case .routes: return "Route library entries and metadata"
        case .lists: return "List metadata plus bulleted route-link text"
        case .allData: return "One combined backup bundle"
        }
    }

    var symbolName: String {
        switch self {
        case .activities: return "figure.run"
        case .routes: return "map"
        case .lists: return "list.bullet"
        case .allData: return "shippingbox"
        }
    }

    var fileStem: String {
        switch self {
        case .activities: return "activities"
        case .routes: return "routes"
        case .lists: return "lists"
        case .allData: return "backup"
        }
    }

    var recordNoun: String {
        switch self {
        case .activities: return "activities"
        case .routes: return "routes"
        case .lists: return "lists"
        case .allData: return "records"
        }
    }

    var supportedFormats: [DataExportFormat] {
        switch self {
        case .allData:
            return [.json]
        case .activities, .routes:
            return [.csv, .json]
        case .lists:
            return [.csv, .json, .markdown]
        }
    }
}

private enum DataExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv:
            return "CSV"
        case .json:
            return "JSON"
        case .markdown:
            return "Bulleted List"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv:
            return "csv"
        case .json:
            return "json"
        case .markdown:
            return "txt"
        }
    }

    var symbolName: String {
        switch self {
        case .csv: return "tablecells"
        case .json: return "curlybraces"
        case .markdown: return "list.bullet.rectangle"
        }
    }

    func description(for dataset: DataExportDataset) -> String {
        switch (self, dataset) {
        case (.csv, _):
            return "Spreadsheet-friendly rows with clean columns for sorting, formulas, and analysis."
        case (.json, .allData):
            return "A structured backup bundle with activities, routes, and lists in one file."
        case (.json, _):
            return "Richer structured data for scripts, notebooks, and re-import workflows."
        case (.markdown, .lists):
            return "Copies plain-text bullets with visible Strava links to the clipboard."
        case (.markdown, _):
            return "Bulleted-list export is only available for lists."
        }
    }
}

private struct PreparedDataExport: Identifiable {
    let id = UUID()
    let url: URL
    let recordCount: Int
}

private struct DataExportMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private enum DataExportBannerTone {
    case error
    case success

    var background: Color {
        switch self {
        case .error:
            return Color(red: 0.38, green: 0.10, blue: 0.10)
        case .success:
            return Color(red: 0.11, green: 0.28, blue: 0.16)
        }
    }

    var foreground: Color {
        switch self {
        case .error:
            return Color(red: 1.0, green: 0.80, blue: 0.80)
        case .success:
            return Color(red: 0.74, green: 0.96, blue: 0.79)
        }
    }
}

private struct DataExportBanner: View {
    let message: String
    let tone: DataExportBannerTone

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DataExportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum DataExportError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "That export format is not available for the selected dataset."
        }
    }
}

private struct ActivityExportRecord: Encodable, DataExportCSVRow {
    let activityKey: String
    let stravaActivityID: Int?
    let source: String
    let name: String
    let description: String
    let sport: String
    let distanceMeters: Double
    let movingTimeSeconds: Double
    let elapsedTimeSeconds: Double
    let elevationGainMeters: Double
    let averageSpeedMetersPerSecond: Double
    let isPrivate: Bool
    let startDate: String
    let updatedAt: String
    let syncedAt: String
    let startAddress: String
    let city: String
    let state: String
    let country: String
    let region: String
    let park: String
    let county: String
    let startLatitude: Double?
    let startLongitude: Double?
    let endLatitude: Double?
    let endLongitude: Double?
    let newCoverageMeters: Double
    let hasDetailedGeometry: Bool
    let geometryPolyline: String
    let elevationSampleCount: Int
    let stravaURL: String
    let uploadedActivityID: Int?
    let lastUploadStatus: String

    init(_ activity: ActivityRecord) {
        activityKey = activity.activityKey
        stravaActivityID = activity.stravaActivityID
        source = activity.sourceKind.rawValue
        name = activity.name
        description = activity.activityDescription
        sport = activity.sportDisplayName
        distanceMeters = activity.distanceMeters
        movingTimeSeconds = activity.movingTime
        elapsedTimeSeconds = activity.elapsedTime
        elevationGainMeters = activity.elevationGainMeters
        averageSpeedMetersPerSecond = activity.averageSpeedMetersPerSecond
        isPrivate = activity.isPrivate
        startDate = ExportDateFormatter.isoString(from: activity.startDate)
        updatedAt = ExportDateFormatter.isoString(from: activity.updatedAt)
        syncedAt = ExportDateFormatter.isoString(from: activity.syncedAt)
        startAddress = activity.startAddressText ?? ""
        city = activity.city
        state = activity.normalizedStateDisplayName
        country = activity.country
        region = activity.startRegionName ?? ""
        park = activity.startParkName ?? ""
        county = activity.startCountyName ?? ""
        startLatitude = activity.startLatitude
        startLongitude = activity.startLongitude
        endLatitude = activity.endLatitude
        endLongitude = activity.endLongitude
        newCoverageMeters = activity.newCoverageMeters
        hasDetailedGeometry = activity.hasDetailedGeometry
        geometryPolyline = activity.activityGeometryPolyline
        elevationSampleCount = activity.elevationSamples.count
        stravaURL = activity.stravaURL?.absoluteString ?? ""
        uploadedActivityID = activity.uploadedActivityID
        lastUploadStatus = activity.lastUploadStatus ?? ""
    }

    static let csvHeader = [
        "activity_key", "strava_activity_id", "source", "name", "description", "sport",
        "distance_meters", "moving_time_seconds", "elapsed_time_seconds", "elevation_gain_meters",
        "average_speed_mps", "is_private", "start_date", "updated_at", "synced_at", "start_address",
        "city", "state", "country", "region", "park", "county", "start_latitude", "start_longitude",
        "end_latitude", "end_longitude", "new_coverage_meters", "has_detailed_geometry",
        "geometry_polyline", "elevation_sample_count", "strava_url", "uploaded_activity_id",
        "last_upload_status"
    ]

    var csvFields: [String] {
        [
            activityKey,
            stravaActivityID.map(String.init) ?? "",
            source,
            name,
            description,
            sport,
            csvNumber(distanceMeters),
            csvNumber(movingTimeSeconds),
            csvNumber(elapsedTimeSeconds),
            csvNumber(elevationGainMeters),
            csvNumber(averageSpeedMetersPerSecond),
            boolString(isPrivate),
            startDate,
            updatedAt,
            syncedAt,
            startAddress,
            city,
            state,
            country,
            region,
            park,
            county,
            optionalNumber(startLatitude),
            optionalNumber(startLongitude),
            optionalNumber(endLatitude),
            optionalNumber(endLongitude),
            csvNumber(newCoverageMeters),
            boolString(hasDetailedGeometry),
            geometryPolyline,
            String(elevationSampleCount),
            stravaURL,
            uploadedActivityID.map(String.init) ?? "",
            lastUploadStatus
        ]
    }
}

private struct RouteExportRecord: Encodable, DataExportCSVRow {
    let stravaRouteID: Int
    let name: String
    let description: String
    let sport: String
    let movement: String
    let surface: String
    let distanceMeters: Double
    let elevationGainMeters: Double
    let estimatedMovingTimeSeconds: Double
    let routeType: Int
    let routeSubType: Int
    let isPrivate: Bool
    let isStarred: Bool
    let createdAt: String
    let updatedAt: String
    let syncedAt: String
    let startAddress: String
    let city: String
    let state: String
    let country: String
    let region: String
    let park: String
    let county: String
    let listNames: String
    let listCount: Int
    let notes: String
    let hasOfflineAssets: Bool
    let hasDetailedGeometry: Bool

    init(_ route: RouteRecord) {
        stravaRouteID = route.stravaRouteID
        name = route.name
        description = route.routeDescription
        sport = route.sportDisplayName
        movement = route.movementKind.title
        surface = route.surfaceKind?.displayName ?? ""
        distanceMeters = route.distanceMeters
        elevationGainMeters = route.elevationGainMeters
        estimatedMovingTimeSeconds = route.estimatedMovingTime
        routeType = route.routeType
        routeSubType = route.routeSubType
        isPrivate = route.isPrivate
        isStarred = route.isStarred
        createdAt = ExportDateFormatter.isoString(from: route.createdAt)
        updatedAt = ExportDateFormatter.isoString(from: route.updatedAt)
        syncedAt = ExportDateFormatter.isoString(from: route.syncedAt)
        startAddress = route.startAddressText ?? ""
        city = route.city
        state = route.state
        country = route.country
        region = route.startRegionName ?? ""
        park = route.startParkName ?? ""
        county = route.startCountyName ?? ""
        listNames = route.listNames.joined(separator: " | ")
        listCount = route.listNames.count
        notes = route.notes
        hasOfflineAssets = route.hasOfflineAssets
        hasDetailedGeometry = route.routeDetailPolyline?.trimmed.nilIfEmpty != nil
    }

    static let csvHeader = [
        "strava_route_id", "name", "description", "sport", "movement", "surface",
        "distance_meters", "elevation_gain_meters", "estimated_moving_time_seconds",
        "route_type", "route_sub_type", "is_private", "is_starred", "created_at",
        "updated_at", "synced_at", "start_address", "city", "state", "country",
        "region", "park", "county", "list_names", "list_count", "notes",
        "has_offline_assets", "has_detailed_geometry"
    ]

    var csvFields: [String] {
        [
            String(stravaRouteID),
            name,
            description,
            sport,
            movement,
            surface,
            csvNumber(distanceMeters),
            csvNumber(elevationGainMeters),
            csvNumber(estimatedMovingTimeSeconds),
            String(routeType),
            String(routeSubType),
            boolString(isPrivate),
            boolString(isStarred),
            createdAt,
            updatedAt,
            syncedAt,
            startAddress,
            city,
            state,
            country,
            region,
            park,
            county,
            listNames,
            String(listCount),
            notes,
            boolString(hasOfflineAssets),
            boolString(hasDetailedGeometry)
        ]
    }
}

private struct ListExportRecord: Encodable, DataExportCSVRow {
    let id: String
    let name: String
    let description: String
    let isPublic: Bool
    let shareCode: String
    let createdAt: String
    let updatedAt: String
    let routeCount: Int
    let routeNames: String
    let missingImportedRouteCount: Int

    init(list: RouteList, memberRoutes: [RouteRecord]) {
        id = list.id
        name = list.name
        description = list.listDescription
        isPublic = list.isPublic
        shareCode = list.shareCode
        createdAt = ExportDateFormatter.isoString(from: list.createdAt)
        updatedAt = ExportDateFormatter.isoString(from: list.updatedAt)
        routeCount = memberRoutes.count
        routeNames = memberRoutes.map(\.name).joined(separator: " | ")
        missingImportedRouteCount = list.importedRouteReferences.count
    }

    static let csvHeader = [
        "id", "name", "description", "is_public", "share_code", "created_at",
        "updated_at", "route_count", "route_names", "missing_imported_route_count"
    ]

    var csvFields: [String] {
        [
            id,
            name,
            description,
            boolString(isPublic),
            shareCode,
            createdAt,
            updatedAt,
            String(routeCount),
            routeNames,
            String(missingImportedRouteCount)
        ]
    }
}

private enum ListMarkdownExportBuilder {
    static func build(
        generatedAt: Date,
        lists: [RouteList],
        memberRoutesProvider: (RouteList) -> [RouteRecord]
    ) -> String {
        var lines: [String] = [
            "# Terigo Lists",
            "",
            "_Exported \(ExportDateFormatter.displayString(from: generatedAt))_",
            ""
        ]

        let sortedLists = lists.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            return $0.updatedAt > $1.updatedAt
        }

        for (index, list) in sortedLists.enumerated() {
            let memberRoutes = memberRoutesProvider(list)

            lines.append("\(list.name)")
            lines.append(String(repeating: "=", count: max(list.name.count, 3)))

            if let description = list.listDescription.trimmed.nilIfEmpty {
                lines.append("")
                lines.append(description)
            }

            lines.append("")

            if memberRoutes.isEmpty {
                lines.append("- No routes in this list yet.")
            } else {
                for route in memberRoutes {
                    lines.append(routeMarkdownBullet(for: route))
                }
            }

            if index < sortedLists.count - 1 {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func routeMarkdownBullet(for route: RouteRecord) -> String {
        let details = [
            RouteDisplayFormatter.distance(route.distanceMeters),
            RouteDisplayFormatter.climb(route.elevationGainMeters),
            RouteDisplayFormatter.duration(route.estimatedMovingTime)
        ]
        .filter { !$0.isEmpty }

        var bullet = "- \(route.name)"
        if !details.isEmpty {
            bullet += " - \(details.joined(separator: " • "))"
        }

        if let routeURL = route.routeURL?.absoluteString {
            return "\(bullet)\n  \(routeURL)"
        }

        return bullet
    }
}

private struct FullDataExportBundle: Encodable {
    let exportedAt: String
    let activities: [ActivityExportRecord]
    let routes: [RouteExportRecord]
    let lists: [ListExportRecord]
}

private protocol DataExportCSVRow {
    static var csvHeader: [String] { get }
    var csvFields: [String] { get }
}

private enum DataExportCSVBuilder {
    static func encode<Row: DataExportCSVRow>(_ rows: [Row]) -> Data {
        var lines = [csvLine(Row.csvHeader)]
        lines.append(contentsOf: rows.map { csvLine($0.csvFields) })
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        let needsQuotes = escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }
}

private enum ExportDateFormatter {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    static func isoString(from date: Date?) -> String {
        guard let date else {
            return ""
        }
        return isoFormatter.string(from: date)
    }

    static func filenameStamp(from date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    static func displayString(from date: Date) -> String {
        displayFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private func csvNumber(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.6f", value)
}

private func optionalNumber(_ value: Double?) -> String {
    guard let value else {
        return ""
    }
    return csvNumber(value)
}

private func boolString(_ value: Bool) -> String {
    value ? "true" : "false"
}
