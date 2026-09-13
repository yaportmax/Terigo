import CoreSpotlight
import MapKit
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ResolvedRouteListReference {
    let reference: RouteListSharedRouteReference
    let route: RouteRecord?
}

func resolveRouteListReferences(
    _ references: [RouteListSharedRouteReference],
    in routes: [RouteRecord]
) -> [ResolvedRouteListReference] {
    let routesByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.stravaRouteID, $0) })
    let uniqueRoutesByName = Dictionary(grouping: routes, by: { $0.name.routeLabelIdentifier })
        .compactMapValues { matches -> RouteRecord? in
            let uniqueMatches = Array(Dictionary(uniqueKeysWithValues: matches.map { ($0.stravaRouteID, $0) }).values)
            return uniqueMatches.count == 1 ? uniqueMatches[0] : nil
        }

    return references.map { reference in
        let matchedRoute = routesByID[reference.routeID] ??
            uniqueRoutesByName[reference.name.routeLabelIdentifier]
        return ResolvedRouteListReference(reference: reference, route: matchedRoute)
    }
}

func deduplicatedResolvedRoutes(_ references: [ResolvedRouteListReference]) -> [RouteRecord] {
    var seen = Set<Int>()
    var routes: [RouteRecord] = []

    for reference in references {
        guard let route = reference.route,
              seen.insert(route.stravaRouteID).inserted else {
            continue
        }

        routes.append(route)
    }

    return routes
}

struct RouteListsScreen: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var allLists: [RouteList]
    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var allRoutes: [RouteRecord]

    let onDeleteList: (RouteList) -> Void

    @State private var isShowingNewList = false
    @State private var newListDraft = ""
    @State private var pendingDeletionList: RouteList?
    @State private var message: String?

    var body: some View {
        let usageCounts = listUsageCounts

        List {
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Section("All Lists") {
                if sortedLists.isEmpty {
                    ContentUnavailableView(
                        "No Lists Yet",
                        systemImage: "list.bullet",
                        description: Text("Create lists here, then add routes to them from route details or quick actions.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(sortedLists) { list in
                        NavigationLink {
                            RouteListDetailScreen(list: list, onDeleteList: onDeleteList)
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: list.sharingVisibility == .privateAccess ? "square.stack" : "person.2")
                                    .font(.title2)
                                    .foregroundStyle(TerigoTheme.accent)
                                    .frame(width: 52, height: 60)
                                    .background(TerigoTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(list.name)
                                        .font(.headline)

                                    HStack(spacing: 8) {
                                        Text(usageLabel(for: list, usageCounts: usageCounts))
                                        Text(list.sharingVisibility.title)
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                if list.sharingVisibility != .privateAccess {
                                    Image(systemName: "link")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("route-list-row-\(list.normalizedName.replacingOccurrences(of: " ", with: "-"))")
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletionList = list
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TerigoTheme.background.ignoresSafeArea())
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isShowingNewList = true } label: {
                    Label("New List", systemImage: "plus")
                }
                .accessibilityIdentifier("lists-create")
            }
        }
        .alert("New List", isPresented: $isShowingNewList) {
            TextField("List name", text: $newListDraft)
            Button("Cancel", role: .cancel) { newListDraft = "" }
            Button("Create", action: addList).disabled(newListDraft.trimmed.isEmpty)
        } message: {
            Text("A place for your next adventure, training block, or favorite routes.")
        }
        .accessibilityIdentifier("manage-lists-screen")
        .confirmationDialog(
            "Delete List?",
            isPresented: pendingDeletionBinding,
            titleVisibility: .visible
        ) {
            if let pendingDeletionList {
                Button("Delete List", role: .destructive) {
                    deleteList(pendingDeletionList)
                }
            }

            Button("Cancel", role: .cancel) {
                pendingDeletionList = nil
            }
        } message: {
            if let pendingDeletionList {
                Text("This removes `\(pendingDeletionList.name)` from every route and deletes the list details.")
            }
        }
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionList != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionList = nil
                }
            }
        )
    }

    private var sortedLists: [RouteList] {
        allLists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var listUsageCounts: [String: Int] {
        Dictionary(grouping: allRoutes.flatMap(\.listNames), by: { $0.routeLabelIdentifier })
            .mapValues(\.count)
    }

    private func addList() {
        let trimmedListName = newListDraft.trimmed
        guard !trimmedListName.isEmpty else {
            return
        }

        guard !allLists.contains(where: { $0.normalizedName == trimmedListName.routeLabelIdentifier }) else {
            message = "A list with that name already exists."
            return
        }

        let list = RouteList(name: trimmedListName)
        modelContext.insert(list)
        do {
            try modelContext.save()
            newListDraft = ""
            message = nil
        } catch {
            modelContext.delete(list)
            message = "Couldn’t create the list. \(error.localizedDescription)"
        }
    }

    private func deleteList(_ list: RouteList) {
        onDeleteList(list)
        pendingDeletionList = nil
    }

    private func usageLabel(for list: RouteList, usageCounts: [String: Int]) -> String {
        let usageCount = usageCounts[list.normalizedName] ?? 0
        return usageCount == 0
            ? "Empty list"
            : "\(usageCount) \(usageCount == 1 ? "route" : "routes")"
    }
}

private struct RouteListDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\RouteRecord.syncedAt, order: .reverse)]) private var allRoutes: [RouteRecord]
    @Query(sort: [SortDescriptor(\RouteList.updatedAt, order: .reverse)]) private var allLists: [RouteList]

    @Bindable var list: RouteList
    let onDeleteList: (RouteList) -> Void

    @State private var libraryModel = RouteLibraryModel()
    @State private var selectedRoute: RouteRecord?
    @State private var isShowingMapBrowse = false
    @State private var isShowingRenamePrompt = false
    @State private var renameDraft: String
    @State private var isShowingDescriptionEditor = false
    @State private var descriptionDraft: String
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var isDownloadingOffline = false
    @State private var offlineDownloadProgress: RouteOfflineDownloadProgress?
    @State private var isShowingSharingSheet = false

    private let offlineDownloadCoordinator = RouteOfflineDownloadCoordinator()

    init(list: RouteList, onDeleteList: @escaping (RouteList) -> Void) {
        self.list = list
        self.onDeleteList = onDeleteList
        _renameDraft = State(initialValue: list.name)
        _descriptionDraft = State(initialValue: list.listDescription)
    }

    var body: some View {
        let sortedLists = allLists.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let snapshot = contentSnapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let errorMessage = visibleBannerMessage(errorMessage ?? libraryModel.errorMessage) {
                    BannerView(message: errorMessage, tone: .error)
                }

                if let statusMessage = visibleBannerMessage(statusMessage ?? libraryModel.statusMessage) {
                    BannerView(message: statusMessage, tone: .success)
                }

                ControlsSection(
                    model: libraryModel,
                    allRoutes: snapshot.routes,
                    lists: sortedLists
                )

                RouteResultsSection(
                    filteredRoutes: snapshot.filteredRoutes,
                    allLists: sortedLists,
                    routeCount: snapshot.routes.count,
                    density: preferredDensity,
                    hasActiveFilters: libraryModel.hasActiveFilters,
                    isSyncing: false,
                    onResetFilters: libraryModel.resetFilters,
                    onDeleteRoute: { route in
                        libraryModel.deleteRoute(route, using: modelContext)
                    },
                    onToggleRouteList: { route, list in
                        route.listNames = route.toggledListNames(with: list.name)
                        do {
                            try modelContext.save()
                        } catch {
                            errorMessage = "Couldn’t save the list change. \(error.localizedDescription)"
                            return
                        }
                        statusMessage = route.hasList(named: list.name)
                            ? "Added \(route.name) to \(list.name)."
                            : "Removed \(route.name) from \(list.name)."
                        errorMessage = nil
                        libraryModel.statusMessage = nil
                        libraryModel.errorMessage = nil
                    },
                    onReportStatus: { message in
                        statusMessage = message
                        errorMessage = nil
                        libraryModel.statusMessage = nil
                        libraryModel.errorMessage = nil
                    },
                    onReportError: { message in
                        errorMessage = message
                    },
                    onSelect: { selectedRoute = $0 },
                    emptyListName: list.name
                )

                if !snapshot.missingImportedRoutes.isEmpty {
                    MissingImportedRoutesPanel(references: snapshot.missingImportedRoutes)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TerigoTheme.background.ignoresSafeArea())
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                listHeaderOverlay(routes: snapshot.routes)
            }
        }
        .accessibilityIdentifier("route-list-detail-screen-\(list.normalizedName.replacingOccurrences(of: " ", with: "-"))")
        .task(id: importedRouteRepairKey) {
            repairImportedRouteMembershipsIfNeeded()
        }
        .alert("Edit List Name", isPresented: $isShowingRenamePrompt) {
            TextField("List name", text: $renameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Save") {
                renameList(to: renameDraft)
            }
            Button("Cancel", role: .cancel) {
                renameDraft = list.name
            }
        }
        .sheet(isPresented: $isShowingDescriptionEditor) {
            NavigationStack {
                RouteListDescriptionEditorSheet(
                    title: list.name,
                    initialDescription: list.listDescription
                ) { updatedDescription in
                    updateDescription(to: updatedDescription)
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isShowingMapBrowse) {
            NavigationStack {
                RouteMapBrowseSheet(
                    model: libraryModel,
                    allRoutes: snapshot.routes,
                    lists: sortedLists
                )
            }
            .presentationDetents([.large])
        }
        .sheet(item: $selectedRoute) { route in
            NavigationStack {
                RouteEditorSheet(
                    route: route,
                    onDelete: { routeToDelete in
                        onDeleteRoute(routeToDelete)
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingSharingSheet) {
            NavigationStack {
                RouteListSharingSheet(list: list, routes: snapshot.routes)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete List?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete List", role: .destructive) {
                onDeleteList(list)
                dismiss()
            }

            Button("Cancel", role: .cancel) { }
        } message: {
            Text(list.remoteAccessRole == .follower
                ? "This removes the followed list from your library."
                : "This removes the list from every route and deletes the list details.")
        }
    }

    @ViewBuilder
    private func listHeaderOverlay(routes: [RouteRecord]) -> some View {
        HStack(spacing: 12) {
            RouteVaultToolbarIconButton(
                systemImage: "map",
                accessibilityLabel: "Open list map",
                accessibilityIdentifier: "route-list-open-map"
            ) {
                isShowingMapBrowse = true
            }
            .disabled(routes.isEmpty)

            Menu {
                Section("View") {
                    Picker("Route View", selection: preferredDensityBinding) {
                        ForEach(AppRouteListDensity.allCases, id: \.self) { density in
                            Label(density.title, systemImage: density.symbolName)
                                .tag(density)
                        }
                    }
                }

                Section("Sharing") {
                    if list.remoteAccessRole?.isOwnedByCurrentAccount != false {
                        Button {
                            isShowingSharingSheet = true
                        } label: {
                            Label("Sharing & Collaboration", systemImage: "person.2")
                        }
                    }

                    Button {
                        copyBulletedListToClipboard(using: routes)
                    } label: {
                        Label("Copy Bulleted List", systemImage: "doc.on.clipboard")
                    }
                    .disabled(routes.isEmpty)
                }

                if list.canSyncRemotelyFromThisDevice {
                    Section("Edit") {
                        Button {
                            renameDraft = list.name
                            isShowingRenamePrompt = true
                        } label: {
                            Label("Edit Name", systemImage: "pencil")
                        }

                        Button {
                            descriptionDraft = list.listDescription
                            isShowingDescriptionEditor = true
                        } label: {
                            Label("Edit Description", systemImage: "text.alignleft")
                        }
                    }
                }

                Section("Offline") {
                    Button {
                        Task { await downloadFullListOffline(routes: routes) }
                } label: {
                    Label(
                        isDownloadingOffline
                            ? (offlineDownloadProgress?.buttonLabel ?? "Downloading Offline…")
                            : (routes.allSatisfy(\.hasOfflineAssets) ? "Refresh Full List Offline Files" : "Download Full List Offline Files"),
                        systemImage: "arrow.down.circle"
                    )
                }
                .accessibilityIdentifier("route-list-download-full-offline")
                .disabled(isDownloadingOffline || routes.isEmpty)
            }

                if list.remoteAccessRole == nil || list.remoteAccessRole == .owner || list.remoteAccessRole == .follower {
                    Section {
                        Button(role: .destructive) {
                            isShowingDeleteConfirmation = true
                        } label: {
                            Label(list.remoteAccessRole == .follower ? "Remove From Library" : "Delete List", systemImage: "trash")
                        }
                    }
                }
            } label: {
                RouteVaultToolbarIconGlyph(systemImage: "ellipsis")
                    .contentShape(Circle())
                    .accessibilityLabel("List settings")
                    .accessibilityIdentifier("route-list-settings-button")
            }
        }
        .allowsHitTesting(true)
    }

    private struct ContentSnapshot {
        let routes: [RouteRecord]
        let filteredRoutes: [RouteRecord]
        let offlineRouteCount: Int
        let missingImportedRoutes: [RouteListSharedRouteReference]
    }

    private var contentSnapshot: ContentSnapshot {
        let resolvedImportedRouteReferences = resolveRouteListReferences(list.importedRouteReferences, in: allRoutes)
        let resolvedImportedRouteIDs = Set(deduplicatedResolvedRoutes(resolvedImportedRouteReferences).map(\.stravaRouteID))
        let routes = allRoutes.filter {
            $0.hasList(named: list.name) || resolvedImportedRouteIDs.contains($0.stravaRouteID)
        }
        let filteredRoutes = libraryModel.filteredRoutes(from: routes)
        let offlineRouteCount = routes.filter(\.hasOfflineAssets).count
        let missingImportedRoutes = resolvedImportedRouteReferences.compactMap {
            $0.route == nil ? $0.reference : nil
        }
        return ContentSnapshot(
            routes: routes,
            filteredRoutes: filteredRoutes,
            offlineRouteCount: offlineRouteCount,
            missingImportedRoutes: missingImportedRoutes
        )
    }

    private var importedRouteRepairKey: String {
        var hasher = Hasher()
        hasher.combine(list.id)
        hasher.combine(list.name)
        for reference in list.importedRouteReferences {
            hasher.combine(reference.routeID)
            hasher.combine(reference.name)
        }
        for route in allRoutes {
            hasher.combine(route.stravaRouteID)
            hasher.combine(route.name)
            hasher.combine(route.hasList(named: list.name))
        }
        return String(hasher.finalize())
    }

    private var preferredDensity: AppRouteListDensity {
        list.preferredDensity
    }

    private var preferredDensityBinding: Binding<AppRouteListDensity> {
        Binding(
            get: { preferredDensity },
            set: { updatePreferredDensity($0) }
        )
    }

    private func repairImportedRouteMembershipsIfNeeded() {
        let resolvedRoutes = deduplicatedResolvedRoutes(resolveRouteListReferences(list.importedRouteReferences, in: allRoutes))
        guard !resolvedRoutes.isEmpty else {
            return
        }

        var didChange = false
        for route in resolvedRoutes where !route.hasList(named: list.name) {
            route.listNames = RouteRecord.normalizedLabels(route.listNames + [list.name])
            didChange = true
        }

        guard didChange else {
            return
        }

        list.touch()
        try? modelContext.save()
    }

    private func visibleBannerMessage(_ value: String?) -> String? {
        guard let message = value?.trimmed.nilIfEmpty else {
            return nil
        }

        if message.caseInsensitiveCompare("cancelled") == .orderedSame {
            return nil
        }

        return message
    }

    private func copyBulletedListToClipboard(using routes: [RouteRecord]) {
        guard !routes.isEmpty else {
            return
        }

        UIPasteboard.general.string = RouteListMarkdownExportBuilder.build(list: list, routes: routes)
        errorMessage = nil
        statusMessage = "Copied bulleted list to the clipboard."
    }

    private func renameList(to candidateName: String) {
        let trimmedName = candidateName.trimmed
        guard !trimmedName.isEmpty else {
            errorMessage = "List name can’t be empty."
            return
        }

        let originalName = list.name
        let normalizedNewName = trimmedName.routeLabelIdentifier
        let hasDuplicate = allLists.contains {
            $0.id != list.id && $0.normalizedName == normalizedNewName
        }

        guard !hasDuplicate else {
            errorMessage = "A different list already uses that name."
            return
        }

        if originalName.routeLabelIdentifier != normalizedNewName {
            for route in allRoutes where route.hasList(named: originalName) {
                route.listNames = route.renamingList(from: originalName, to: trimmedName)
            }

            libraryModel.selectedCollections = Set(
                libraryModel.selectedCollections.map {
                    $0.routeLabelIdentifier == originalName.routeLabelIdentifier ? trimmedName : $0
                }
            )
        }

        list.name = trimmedName
        persistListChanges(status: "Renamed list to \(trimmedName).")
        renameDraft = trimmedName
    }

    private func updateDescription(to description: String) {
        list.listDescription = description.trimmed
        descriptionDraft = list.listDescription
        persistListChanges(status: list.hasDescription ? "Updated list description." : "Removed list description.")
    }

    private func updatePreferredDensity(_ density: AppRouteListDensity) {
        guard list.preferredDensity != density else {
            return
        }

        list.preferredDensity = density
        persistListChanges(status: "List view set to \(density.title.lowercased()).")
    }

    private func persistListChanges(status: String? = nil) {
        list.touch()

        do {
            try modelContext.save()
            errorMessage = nil
            if let status {
                statusMessage = status
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func onDeleteRoute(_ route: RouteRecord) {
        selectedRoute = nil
        modelContext.delete(route)
        try? modelContext.save()
    }

    @MainActor
    private func downloadFullListOffline(routes: [RouteRecord]) async {
        guard !routes.isEmpty else {
            statusMessage = "This list doesn’t have any routes yet."
            return
        }

        guard !isDownloadingOffline else {
            statusMessage = "Offline files are already downloading for this list."
            return
        }

        isDownloadingOffline = true
        errorMessage = nil
        statusMessage = nil
        offlineDownloadProgress = nil
        defer {
            isDownloadingOffline = false
            offlineDownloadProgress = nil
        }

        var completed = 0
        var failures: [String] = []

        for route in routes {
            let routeName = route.name
            statusMessage = "Downloading \(routeName)…"

            do {
                let storedAssets = try await offlineDownloadCoordinator.storeOfflineBundle(
                    for: route,
                    progress: { progress in
                        Task { @MainActor in
                            offlineDownloadProgress = progress
                            let percentageSuffix = progress.percentageText.map { " \($0)" } ?? ""
                            statusMessage = "Downloading \(routeName)…\(percentageSuffix)"
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
        }

        do {
            try modelContext.save()
        } catch {
            failures.append(error.localizedDescription)
        }

        if completed > 0 {
            statusMessage = completed == 1
                ? "Saved offline files for 1 route in this list."
                : "Saved offline files for \(completed) routes in this list."
        }

        if !failures.isEmpty {
            errorMessage = failures.count == 1
                ? failures[0]
                : "\(failures.count) routes could not be saved offline. \(failures[0])"
        }
    }
}

private struct MissingImportedRoutesPanel: View {
    let references: [RouteListSharedRouteReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Missing From This Device")
                .font(.headline)

            ForEach(references) { reference in
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Route ID \(reference.routeID)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .routePanelSurface(cornerRadius: 28)
    }
}

private struct RouteListDescriptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @State private var descriptionText: String
    let onSave: (String) -> Void

    init(title: String, initialDescription: String, onSave: @escaping (String) -> Void) {
        self.title = title
        _descriptionText = State(initialValue: initialDescription)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Description")
                .font(.headline)

            TextEditor(text: $descriptionText)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 180)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(20)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    onSave(descriptionText)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }
}

private enum RouteListMarkdownExportBuilder {
    static func build(list: RouteList, routes: [RouteRecord]) -> String {
        var lines: [String] = [
            "# \(list.name)",
            ""
        ]

        if let description = list.listDescription.trimmed.nilIfEmpty {
            lines.append(description)
            lines.append("")
        }

        if routes.isEmpty {
            lines.append("- No routes in this list yet.")
            return lines.joined(separator: "\n")
        }

        for route in routes {
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
            lines.append(bullet)

            if let routeURL = route.routeURL?.absoluteString {
                lines.append("  \(routeURL)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
