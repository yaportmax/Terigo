import Charts
import CoreLocation
import MapboxMaps
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ActivitiesScreen: View {
    let showsDismissButton: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\ActivityRecord.startDate, order: .reverse)]) private var activities: [ActivityRecord]
    @AppStorage(AppMeasurementSystem.storageKey) private var measurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue
    @AppStorage(AppActivityListDensity.storageKey) private var activityListDensityRawValue = AppActivityListDensity.defaultValue.rawValue

    @State private var model = ActivitiesModel()
    @State private var isShowingGPXImporter = false
    @State private var isShowingSettingsSheet = false
    @State private var statusBannerDismissTask: Task<Void, Never>?

    private var measurementSystem: AppMeasurementSystem {
        AppMeasurementSystem(rawValue: measurementSystemRawValue) ?? .defaultValue
    }

    private var activityListDensity: AppActivityListDensity {
        AppActivityListDensity(rawValue: activityListDensityRawValue) ?? AppActivityListDensity.defaultValue
    }

    private var activityListDensitySelection: Binding<AppActivityListDensity> {
        Binding(
            get: { activityListDensity },
            set: { activityListDensityRawValue = $0.rawValue }
        )
    }

    private var filteredActivities: [ActivityRecord] {
        model.filteredActivities(from: activities)
    }

    private var filteredActivitySummary: ActivitiesModel.ActivityListSummarySnapshot {
        model.activityListSummary(from: filteredActivities)
    }

    private var analyticsBlockingState: ActivitiesModel.AnalyticsBlockingState? {
        model.analyticsBlockingState(for: activities)
    }

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    bannerStack
                    connectionSection
                    activitiesTopActions

                    if model.isConnected {
                        activitiesTab
                    }
                }
                .padding(20)
            }
        }
        .accessibilityIdentifier("activities-screen")
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Activities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: {
            if showsDismissButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }

        })
        .sheet(isPresented: $isShowingSettingsSheet) {
            NavigationStack {
                ActivitiesSettingsSheet(
                    activityListDensitySelection: activityListDensitySelection,
                    isConnected: model.isConnected,
                    isSyncing: model.isSyncing,
                    isConnecting: model.isConnecting,
                    isImportingLocalActivities: model.isImportingLocalActivities,
                    onSyncActivities: { Task { await model.syncActivities(using: modelContext) } },
                    onImportGPXActivity: { isShowingGPXImporter = true },
                    onReconnectStrava: { Task { await model.connect() } },
                    onDisconnectStrava: { model.disconnect() }
                )
            }
            .presentationDetents([.medium])
        }
        .task {
            await Task.yield()
            await model.prime(using: modelContext, existingActivities: activities)
        }
        .onChange(of: model.statusMessage) { _, newValue in
            scheduleStatusBannerDismiss(for: newValue)
        }
        .fileImporter(
            isPresented: $isShowingGPXImporter,
            allowedContentTypes: [.gpxActivity],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await model.importLocalActivities(from: urls, using: modelContext) }
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            statusBannerDismissTask?.cancel()
            statusBannerDismissTask = nil
        }
        .navigationDestination(for: String.self) { activityKey in
            if let activity = activities.first(where: { $0.activityKey == activityKey }) {
                DeferredActivityDetailScreen(activity: activity, model: model)
            } else {
                ContentUnavailableView(
                    "Activity Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This activity is no longer available locally.")
                )
                .background(Color.black.ignoresSafeArea())
            }
        }
    }

    @ViewBuilder
    private var bannerStack: some View {
        if let errorMessage = visibleBannerMessage(model.errorMessage) {
            ActivitiesBannerView(message: errorMessage, tone: .error)
        }

        if let analyticsBlockingState {
            ActivitiesBannerView(
                message: analyticsBlockingState.progressLabel.map { "\(analyticsBlockingState.title). \($0)." }
                    ?? analyticsBlockingState.title,
                tone: .progress
            )
        }

        if let statusMessage = visibleBannerMessage(model.statusMessage) {
            ActivitiesBannerView(message: statusMessage, tone: .success)
        }
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

    private func scheduleStatusBannerDismiss(for value: String?) {
        statusBannerDismissTask?.cancel()
        statusBannerDismissTask = nil

        guard let message = visibleBannerMessage(value) else {
            return
        }

        statusBannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else {
                return
            }

            if model.statusMessage == message {
                model.statusMessage = nil
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if !model.isConnected {
            ActivityConnectionCard(
                title: "Connect Strava",
                message: "Sync past activities, open detailed workout views, and pull routes out of them into your library.",
                buttonTitle: model.isConnecting ? "Connecting…" : "Connect Strava",
                buttonAction: {
                    Task { await model.connect() }
                }
            )
        } else if model.requiresReconnectForActivities {
            ActivityConnectionCard(
                title: "Reconnect For Activity Access",
                message: "This Strava session can still sync routes, but it needs activity scopes for history sync, workout detail refresh, and uploads.",
                buttonTitle: model.isConnecting ? "Reconnecting…" : "Reconnect Strava",
                buttonAction: {
                    Task { await model.connect() }
                }
            )
        }
    }

    private var activitiesTopActions: some View {
        HStack {
            Spacer()

            Button {
                isShowingSettingsSheet = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Activities settings")
            .accessibilityIdentifier("activities-settings-button")
        }
    }

    private var activitiesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActivitiesControlsSection(
                model: model,
                allActivities: activities,
                summary: filteredActivitySummary
            )

            if filteredActivities.isEmpty {
                ContentUnavailableView(
                    activities.isEmpty ? "No Activities Yet" : "No Matching Activities",
                    systemImage: "figure.run",
                    description: Text(activities.isEmpty
                        ? "Sync Strava or import a GPX activity to start building your activity history."
                        : "Try a different search query."
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                LazyVStack(spacing: activityListDensity.stackSpacing) {
                    ForEach(filteredActivities) { activity in
                        NavigationLink(value: activity.activityKey) {
                            ActivityListRow(activity: activity, density: activityListDensity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("activity-row-\(activity.activityKey)")
                    }
                }
                .id("activities-list-\(activityListDensityRawValue)-\(measurementSystemRawValue)")
            }
        }
    }
}

private struct ActivitiesSettingsSheet: View {
    @Binding var activityListDensitySelection: AppActivityListDensity

    let isConnected: Bool
    let isSyncing: Bool
    let isConnecting: Bool
    let isImportingLocalActivities: Bool
    let onSyncActivities: () -> Void
    let onImportGPXActivity: () -> Void
    let onReconnectStrava: () -> Void
    let onDisconnectStrava: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Activity View") {
                Picker("Activity View", selection: $activityListDensitySelection) {
                    ForEach(AppActivityListDensity.allCases) { density in
                        Label(density.title, systemImage: density.symbolName)
                            .tag(density)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Actions") {
                if isConnected {
                    Button(action: onSyncActivities) {
                        Label(isSyncing ? "Syncing…" : "Sync Activities", systemImage: "arrow.clockwise")
                    }
                    .disabled(isSyncing)
                }

                Button(action: onImportGPXActivity) {
                    Label(
                        isImportingLocalActivities ? "Importing…" : "Import GPX Activity",
                        systemImage: "square.and.arrow.down.on.square"
                    )
                }
                .disabled(isImportingLocalActivities)
            }

            Section("Connection") {
                if isConnected {
                    Button(action: onReconnectStrava) {
                        Label("Reconnect Strava", systemImage: "link.badge.plus")
                    }

                    Button("Disconnect", role: .destructive, action: onDisconnectStrava)
                } else {
                    Button(action: onReconnectStrava) {
                        Label(
                            isConnecting ? "Connecting…" : "Connect Strava",
                            systemImage: "person.crop.circle.badge.plus"
                        )
                    }
                    .disabled(isConnecting)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Activities Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("activities-settings-sheet")
    }
}

private struct DeferredActivityDetailScreen: View {
    @Bindable var activity: ActivityRecord
    let model: ActivitiesModel

    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                ActivityDetailScreen(activity: activity, model: model)
            } else {
                ActivityDetailLoadingScreen(title: activity.name)
            }
        }
        .task {
            guard !isReady else {
                return
            }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else {
                return
            }

            isReady = true
        }
    }
}

private struct ActivityDetailLoadingScreen: View {
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .tint(.white)
            Text("Loading \(title)…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ActivitiesBannerTone {
    case success
    case error
    case progress

    var background: Color {
        switch self {
        case .success:
            return Color(red: 0.11, green: 0.36, blue: 0.21).opacity(0.9)
        case .error:
            return Color(red: 0.35, green: 0.10, blue: 0.10).opacity(0.92)
        case .progress:
            return Color(red: 0.14, green: 0.16, blue: 0.22).opacity(0.92)
        }
    }

    var foreground: Color {
        switch self {
        case .success:
            return Color(red: 0.69, green: 0.94, blue: 0.74)
        case .error:
            return Color(red: 1.0, green: 0.82, blue: 0.82)
        case .progress:
            return Color(red: 0.82, green: 0.88, blue: 1.0)
        }
    }
}

private struct ActivitiesBannerView: View {
    let message: String
    let tone: ActivitiesBannerTone

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct ActivityConnectionCard: View {
    let title: String
    let message: String
    let buttonTitle: String
    let buttonAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: buttonAction) {
                Label(buttonTitle, systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.black)
                    .background(Color(red: 1.0, green: 0.67, blue: 0.48), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ActivitySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search activities, places, sports", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ActivitiesControlsSection: View {
    @Bindable var model: ActivitiesModel
    let allActivities: [ActivityRecord]
    let summary: ActivitiesModel.ActivityListSummarySnapshot

    @State private var isShowingSortSheet = false
    @State private var isShowingFiltersSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivitySearchField(text: $model.query)

            HStack(spacing: 12) {
                ActivitiesActionControlChip(
                    title: "Sort",
                    symbolName: model.sortCriteria.first?.option.symbolName ?? ActivitySortCriterion.defaultCriterion.option.symbolName,
                    isActive: model.hasCustomSortCriteria,
                    accessibilityIdentifier: "activities-sort-button"
                ) {
                    isShowingSortSheet = true
                }

                ActivitiesActionControlChip(
                    title: "Filters",
                    symbolName: "line.3.horizontal.decrease.circle",
                    isActive: model.hasActiveFilters,
                    accessibilityIdentifier: "activities-filters-button"
                ) {
                    isShowingFiltersSheet = true
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(controlsSummaryLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ActivitiesSummaryStrip(summary: summary)
            }
        }
        .sheet(isPresented: $isShowingSortSheet) {
            NavigationStack {
                ActivitiesSortSheet(model: model)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingFiltersSheet) {
            NavigationStack {
                ActivitiesFiltersSheet(model: model, allActivities: allActivities)
            }
            .presentationDetents([.large])
        }
    }

    private var controlsSummaryLine: String {
        "\(sortSummary) · \(filterSummary)"
    }

    private var sortSummary: String {
        guard model.hasCustomSortCriteria else {
            return ActivitySortCriterion.defaultCriterion.option.title
        }

        guard let firstCriterion = model.sortCriteria.first else {
            return ActivitySortCriterion.defaultCriterion.option.title
        }

        if model.sortCriteria.count == 1 {
            return firstCriterion.option.title
        }

        return "\(firstCriterion.option.title) +\(model.sortCriteria.count - 1)"
    }

    private var filterSummary: String {
        let count = activeFilterCount
        guard count > 0 else {
            return "All activities"
        }
        if count == 1, let primaryFilterSummary {
            return primaryFilterSummary
        }
        return "\(count) filters active"
    }

    private var activeFilterCount: Int {
        var count = 0
        if !model.selectedSports.isEmpty { count += 1 }
        if !model.selectedSources.isEmpty { count += 1 }
        if model.privacyFilter != .all { count += 1 }
        if model.minimumDistanceMeters != nil || model.maximumDistanceMeters != nil { count += 1 }
        if model.minimumClimbMeters != nil || model.maximumClimbMeters != nil { count += 1 }
        return count
    }

    private var primaryFilterSummary: String? {
        if !model.selectedSports.isEmpty {
            return model.selectedSports.count == 1
                ? "Sport: \(model.selectedSports.first?.title ?? "1")"
                : "Sport: \(model.selectedSports.count)"
        }
        if !model.selectedSources.isEmpty {
            return model.selectedSources.count == 1
                ? "Source: \(model.selectedSources.first?.title ?? "1")"
                : "Source: \(model.selectedSources.count)"
        }
        if model.privacyFilter != .all {
            return "Privacy: \(model.privacyFilter.title)"
        }
        if model.minimumDistanceMeters != nil || model.maximumDistanceMeters != nil {
            return "Distance range"
        }
        if model.minimumClimbMeters != nil || model.maximumClimbMeters != nil {
            return "Climb range"
        }
        return nil
    }
}

private struct ActivitiesActionControlChip: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIconGlyph(name: symbolName, size: 14, weight: .semibold)
                    .foregroundStyle(isActive ? Color(red: 0.79, green: 0.32, blue: 0.15) : Color.secondary)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .activitiesControlSurface(isActive: isActive, cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ActivitiesSortSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ActivitiesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Sort Order")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)

                        Spacer(minLength: 0)

                        if model.hasCustomSortCriteria {
                            Button("Reset") {
                                model.resetSort()
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.67, blue: 0.48))
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(spacing: 12) {
                        ForEach(model.sortCriteria) { criterion in
                            ActivitiesSortCriterionRow(
                                criterion: criterion,
                                availableOptions: availableSortOptions(for: criterion),
                                canMoveUp: model.sortCriteria.first?.id != criterion.id,
                                canMoveDown: model.sortCriteria.last?.id != criterion.id,
                                canRemove: model.sortCriteria.count > 1,
                                onSelectOption: { model.updateSortCriterion(criterion.id, option: $0) },
                                onToggleDirection: {
                                    let direction: RouteSortDirection = criterion.direction == .descending ? .ascending : .descending
                                    model.updateSortCriterion(criterion.id, direction: direction)
                                },
                                onMoveUp: { model.moveSortCriterion(criterion.id, by: -1) },
                                onMoveDown: { model.moveSortCriterion(criterion.id, by: 1) },
                                onRemove: { model.removeSortCriterion(criterion.id) }
                            )
                        }
                    }

                    if !availableAdditionalSorts.isEmpty {
                        Menu {
                            ForEach(availableAdditionalSorts) { option in
                                Button {
                                    model.addSortCriterion(option)
                                } label: {
                                    Label(option.title, systemImage: option.symbolName)
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.subheadline.weight(.bold))
                                Text("Add Sort Criterion")
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .activitiesControlSurface(isActive: false, cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Sort Order")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activities-sort-screen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }

    private func availableSortOptions(for criterion: ActivitySortCriterion) -> [ActivitySortOption] {
        ActivitySortOption.allCases.filter { option in
            option == criterion.option || !model.sortCriteria.contains(where: { $0.option == option })
        }
    }

    private var availableAdditionalSorts: [ActivitySortOption] {
        ActivitySortOption.allCases.filter { option in
            !model.sortCriteria.contains(where: { $0.option == option })
        }
    }
}

private struct ActivitiesSortCriterionRow: View {
    let criterion: ActivitySortCriterion
    let availableOptions: [ActivitySortOption]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let onSelectOption: (ActivitySortOption) -> Void
    let onToggleDirection: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(availableOptions) { option in
                        Button {
                            onSelectOption(option)
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        AppIconGlyph(name: criterion.option.symbolName, size: 14, weight: .semibold)
                            .foregroundStyle(.white)
                        Text(criterion.option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .activitiesControlSurface(isActive: false, cornerRadius: 18)
                }
                .buttonStyle(.plain)

                Button(action: onToggleDirection) {
                    HStack(spacing: 8) {
                        Image(systemName: criterion.direction.symbolName)
                            .font(.caption.weight(.semibold))
                        Text(criterion.direction.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .activitiesControlSurface(isActive: false, cornerRadius: 18)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                ActivitiesSortReorderButton(symbolName: "arrow.up", isEnabled: canMoveUp, action: onMoveUp)
                ActivitiesSortReorderButton(symbolName: "arrow.down", isEnabled: canMoveDown, action: onMoveDown)
                ActivitiesSortReorderButton(symbolName: "minus.circle", isEnabled: canRemove, action: onRemove)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ActivitiesSortReorderButton: View {
    let symbolName: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(isEnabled ? .white : .secondary.opacity(0.4))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct ActivitiesFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ActivitiesModel
    let allActivities: [ActivityRecord]

    @AppStorage(AppMeasurementSystem.storageKey) private var measurementSystemRawValue = AppMeasurementSystem.defaultValue.rawValue

    @State private var minimumDistanceInput = ""
    @State private var maximumDistanceInput = ""
    @State private var minimumClimbInput = ""
    @State private var maximumClimbInput = ""

    private let rangeFieldColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var measurementSystem: AppMeasurementSystem {
        AppMeasurementSystem(rawValue: measurementSystemRawValue) ?? .defaultValue
    }

    private var availableSports: [RouteSportKind] {
        let counts = Dictionary(grouping: allActivities, by: \.sportKind).mapValues(\.count)
        return counts.keys.sorted { lhs, rhs in
            let lhsCount = counts[lhs, default: 0]
            let rhsCount = counts[rhs, default: 0]
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Activity")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        if model.hasActiveFilters {
                            Button("Reset") {
                                model.resetFilters()
                                syncRangeInputsFromModel()
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.67, blue: 0.48))
                            .buttonStyle(.plain)
                        }
                    }

                    if !availableSports.isEmpty {
                        LazyVGrid(columns: rangeFieldColumns, spacing: 10) {
                            ForEach(availableSports) { sport in
                                ActivitiesSelectionPill(
                                    title: sport.title,
                                    symbolName: sport.symbolName,
                                    isSelected: model.selectedSports.contains(sport)
                                ) {
                                    toggleSport(sport)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Source")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    LazyVGrid(columns: rangeFieldColumns, spacing: 10) {
                        ForEach(ActivitySourceKind.allCases, id: \.rawValue) { source in
                            ActivitiesSelectionPill(
                                title: source.title,
                                symbolName: source == .strava ? "link" : "square.and.arrow.down.on.square",
                                isSelected: model.selectedSources.contains(source)
                            ) {
                                toggleSource(source)
                            }
                        }
                    }
                }
                .padding(18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Privacy")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    HStack(spacing: 10) {
                        ForEach(ActivityPrivacyFilter.allCases) { filter in
                            ActivitiesSelectionPill(
                                title: filter.title,
                                symbolName: filter == .all ? "circle.grid.2x2" : filter == .private ? "lock" : "globe",
                                isSelected: model.privacyFilter == filter
                            ) {
                                model.privacyFilter = filter
                            }
                        }
                    }
                }
                .padding(18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Ranges")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    ActivitiesRangeEditor(
                        title: "Distance",
                        minimumTitle: "Min \(measurementSystem.distanceUnitLabel)",
                        maximumTitle: "Max \(measurementSystem.distanceUnitLabel)",
                        minimumValue: $minimumDistanceInput,
                        maximumValue: $maximumDistanceInput
                    )

                    ActivitiesRangeEditor(
                        title: "Climb",
                        minimumTitle: "Min \(measurementSystem.climbUnitLabel)",
                        maximumTitle: "Max \(measurementSystem.climbUnitLabel)",
                        minimumValue: $minimumClimbInput,
                        maximumValue: $maximumClimbInput
                    )
                }
                .padding(18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Filters")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activities-filters-screen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .onAppear {
            syncRangeInputsFromModel()
        }
        .onChange(of: minimumDistanceInput) { _, _ in applyRangeInputs() }
        .onChange(of: maximumDistanceInput) { _, _ in applyRangeInputs() }
        .onChange(of: minimumClimbInput) { _, _ in applyRangeInputs() }
        .onChange(of: maximumClimbInput) { _, _ in applyRangeInputs() }
    }

    private func toggleSport(_ sport: RouteSportKind) {
        if model.selectedSports.contains(sport) {
            model.selectedSports.remove(sport)
        } else {
            model.selectedSports.insert(sport)
        }
    }

    private func toggleSource(_ source: ActivitySourceKind) {
        if model.selectedSources.contains(source) {
            model.selectedSources.remove(source)
        } else {
            model.selectedSources.insert(source)
        }
    }

    private func syncRangeInputsFromModel() {
        minimumDistanceInput = displayRangeValue(forMeters: model.minimumDistanceMeters)
        maximumDistanceInput = displayRangeValue(forMeters: model.maximumDistanceMeters)
        minimumClimbInput = displayClimbValue(forMeters: model.minimumClimbMeters)
        maximumClimbInput = displayClimbValue(forMeters: model.maximumClimbMeters)
    }

    private func applyRangeInputs() {
        model.minimumDistanceMeters = parsedDistanceValue(minimumDistanceInput)
        model.maximumDistanceMeters = parsedDistanceValue(maximumDistanceInput)
        model.minimumClimbMeters = parsedClimbValue(minimumClimbInput)
        model.maximumClimbMeters = parsedClimbValue(maximumClimbInput)
    }

    private func displayRangeValue(forMeters meters: Double?) -> String {
        guard let meters else {
            return ""
        }

        switch measurementSystem {
        case .metric:
            return localizedNumericString(meters / 1_000)
        case .imperial:
            return localizedNumericString(meters * 0.000621371)
        }
    }

    private func displayClimbValue(forMeters meters: Double?) -> String {
        guard let meters else {
            return ""
        }

        switch measurementSystem {
        case .metric:
            return localizedNumericString(meters)
        case .imperial:
            return localizedNumericString(meters * 3.28084)
        }
    }

    private func parsedDistanceValue(_ rawValue: String) -> Double? {
        guard let numericValue = RouteDisplayFormatter.parseNumericInput(rawValue),
              numericValue > 0 else {
            return nil
        }

        switch measurementSystem {
        case .metric:
            return numericValue * 1_000
        case .imperial:
            return numericValue * 1_609.34
        }
    }

    private func parsedClimbValue(_ rawValue: String) -> Double? {
        guard let numericValue = RouteDisplayFormatter.parseNumericInput(rawValue),
              numericValue > 0 else {
            return nil
        }

        switch measurementSystem {
        case .metric:
            return numericValue
        case .imperial:
            return numericValue * 0.3048
        }
    }

    private func localizedNumericString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 100 ? 1 : 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}

private struct ActivitiesSelectionPill: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    private var usesActivityGlyph: Bool {
        symbolName.hasPrefix("activity-")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIconGlyph(name: symbolName, size: 16, weight: .semibold)
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
                    .frame(width: usesActivityGlyph ? 24 : 18, height: 22)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.79, green: 0.32, blue: 0.15) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .activitiesControlSurface(isActive: isSelected, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct ActivitiesRangeEditor: View {
    let title: String
    let minimumTitle: String
    let maximumTitle: String
    @Binding var minimumValue: String
    @Binding var maximumValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ActivitiesRangeField(title: minimumTitle, text: $minimumValue)
                ActivitiesRangeField(title: maximumTitle, text: $maximumValue)
            }
        }
    }
}

private struct ActivitiesRangeField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            TextField("Any", text: $text)
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private extension View {
    @ViewBuilder
    func activitiesControlSurface(isActive: Bool, cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(
                    isActive
                        ? .regular.tint(Color(red: 0.95, green: 0.63, blue: 0.48)).interactive()
                        : .regular.interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isActive ? Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isActive ? Color(red: 0.95, green: 0.63, blue: 0.48).opacity(0.35) : Color.primary.opacity(0.08),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private extension ActivitySourceKind {
    var title: String {
        switch self {
        case .strava:
            return "Strava"
        case .local:
            return "Local"
        }
    }
}

private struct ActivitiesSummaryStrip: View {
    let summary: ActivitiesModel.ActivityListSummarySnapshot

    var body: some View {
        Text("\(RouteDisplayFormatter.compactCount(summary.activityCount)) activities · \(RouteDisplayFormatter.distance(summary.distanceMeters)) total")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityMiniMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ActivityListRow: View {
    let activity: ActivityRecord
    let density: AppActivityListDensity

    var body: some View {
        switch density {
        case .compact:
            CompactActivityListRow(activity: activity)
        case .medium:
            ActivityCardRow(activity: activity, density: density)
        case .expanded:
            ExpandedActivityCardRow(activity: activity, density: density)
        }
    }
}

private struct CompactActivityListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let activity: ActivityRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(activity.name)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if activity.isUploadedToStrava {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.54, green: 0.88, blue: 0.64))
                    }

                    Text(RouteDisplayFormatter.calendarDate(activity.startDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 10) {
                ActivityCompactInlineMetric(iconName: activity.sportSymbolName, text: RouteDisplayFormatter.distance(activity.distanceMeters))
                ActivityCompactInlineMetric(iconName: "mountain.2.fill", text: RouteDisplayFormatter.climb(activity.elevationGainMeters))
                ActivityCompactInlineMetric(iconName: "clock.fill", text: RouteDisplayFormatter.duration(max(activity.movingTime, activity.elapsedTime)))
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 10) {
                Text(compactMetaLine)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 2)
        }
    }

    private var compactMetaLine: String {
        var components = [activity.sportDisplayName, activity.sourceKind == .strava ? "Strava" : "Local"]
        if activity.isPrivate {
            components.append("Private")
        }
        return components.joined(separator: " • ")
    }
}

private struct ActivityCardRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let activity: ActivityRecord
    let density: AppActivityListDensity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconGlyph(name: activity.sportSymbolName, size: 16)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)

                    Text(activity.displayLocation.nilIfEmpty ?? activity.startCoordinate?.formattedLabel ?? "Location unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(RouteDisplayFormatter.calendarDate(activity.startDate))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)

                    Text(activity.sourceKind == .strava ? "Strava" : "Local")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activity.sourceKind == .strava ? Color.orange : Color(red: 0.61, green: 0.82, blue: 1.0))
                }
            }

            HStack(spacing: 10) {
                ActivityMetricChip(iconName: "ruler", value: RouteDisplayFormatter.distance(activity.distanceMeters))
                ActivityMetricChip(iconName: "mountain.2", value: RouteDisplayFormatter.climb(activity.elevationGainMeters))
                ActivityMetricChip(iconName: "clock", value: RouteDisplayFormatter.duration(max(activity.movingTime, activity.elapsedTime)))
            }

            HStack(spacing: 8) {
                Text(activity.sportDisplayName)
                if activity.isPrivate {
                    Text("Private")
                }
                if activity.isUploadedToStrava {
                    Text("Uploaded")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(density.contentPadding)
        .background(cardBackground)
        .overlay(cardOutline)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.04))
    }

    private var cardOutline: some View {
        RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
    }
}

private struct ExpandedActivityCardRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let activity: ActivityRecord
    let density: AppActivityListDensity

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AppIconGlyph(name: activity.sportSymbolName, size: 18)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.name)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)

                    Text(activity.displayLocation.nilIfEmpty ?? activity.startCoordinate?.formattedLabel ?? "Location unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(RouteDisplayFormatter.calendarDate(activity.startDate))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)

                    Text(activity.sourceKind == .strava ? "Strava" : "Local")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activity.sourceKind == .strava ? Color.orange : Color(red: 0.61, green: 0.82, blue: 1.0))
                }
            }

            HStack(spacing: 10) {
                ActivityMetricChip(iconName: "ruler", value: RouteDisplayFormatter.distance(activity.distanceMeters))
                ActivityMetricChip(iconName: "mountain.2", value: RouteDisplayFormatter.climb(activity.elevationGainMeters))
                ActivityMetricChip(iconName: "clock", value: RouteDisplayFormatter.duration(max(activity.movingTime, activity.elapsedTime)))
            }

            HStack(spacing: 8) {
                Text(activity.sportDisplayName)
                if activity.isPrivate {
                    Text("Private")
                }
                if activity.isUploadedToStrava {
                    Text("Uploaded")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if let description = activity.activityDescription.trimmed.nilIfEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(density.contentPadding)
        .background(cardBackground)
        .overlay(cardOutline)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.04))
    }

    private var cardOutline: some View {
        RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 1)
    }
}

private struct ActivityCompactInlineMetric: View {
    let iconName: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            AppIconGlyph(name: iconName, size: 13)
                .frame(width: 16, height: 16)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
    }
}

private struct ActivityMetricChip: View {
    let iconName: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(value)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.07), in: Capsule())
    }
}

private struct ActivityDetailScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var activity: ActivityRecord
    let model: ActivitiesModel

    @State private var isShowingMap = false
    @State private var isRefreshing = false
    @State private var isSavingRoute = false
    @State private var isUploading = false

    private var effortAnalysis: ActivityEffortAnalysis? {
        activity.effortAnalysis
    }

    private var resolvedMovingTime: Double {
        activity.movingTime > 0 ? activity.movingTime : max(activity.elapsedTime, 0)
    }

    private var resolvedElapsedTime: Double {
        max(activity.elapsedTime, resolvedMovingTime)
    }

    private var pausedDuration: Double {
        max(resolvedElapsedTime - resolvedMovingTime, 0)
    }

    private var usesPacePresentation: Bool {
        activity.sportKind.movementKind == .onFoot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if isShowingMap {
                        ActivityRouteMapCard(
                            activity: activity,
                            userInterfaceStyle: colorScheme == .dark ? .dark : .light
                        )
                    } else {
                        ActivityRouteMapPlaceholderCard()
                    }
                }
                .frame(height: 280)

                actionSection
                overviewSection
                workoutMetricsSection
                workoutAnalysisSection
                terrainAndPacingSection
                conditionsAndDataQualitySection
                analysisNotesSection
                if let description = activity.activityDescription.trimmed.nilIfEmpty {
                    detailCard(title: "Description") {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(activity.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-detail-screen-\(activity.activityKey)")
        .task {
            guard !isShowingMap else {
                return
            }

            await Task.yield()
            isShowingMap = true
        }
    }

    private var actionSection: some View {
        detailCard(title: "Actions") {
            VStack(spacing: 12) {
                actionButton(
                    title: isSavingRoute ? "Saving Route…" : "Save Route To Library",
                    systemImage: "plus.square.on.square",
                    tint: Color(red: 1.0, green: 0.64, blue: 0.18)
                ) {
                    Task {
                        isSavingRoute = true
                        model.saveActivityAsRoute(activity, using: modelContext)
                        isSavingRoute = false
                    }
                }

                if activity.sourceKind == .strava {
                    actionButton(
                        title: isRefreshing ? "Refreshing…" : "Refresh Activity",
                        systemImage: "arrow.clockwise",
                        tint: Color(red: 0.61, green: 0.82, blue: 1.0)
                    ) {
                        Task {
                            isRefreshing = true
                            await model.refreshActivityDetail(activity, using: modelContext)
                            isRefreshing = false
                        }
                    }
                }

                if activity.sourceKind == .local {
                    actionButton(
                        title: isUploading ? "Uploading…" : "Upload To Strava",
                        systemImage: "arrow.up.circle",
                        tint: Color(red: 0.54, green: 0.88, blue: 0.64)
                    ) {
                        Task {
                            isUploading = true
                            await model.uploadActivity(activity, using: modelContext)
                            isUploading = false
                        }
                    }
                    .disabled(!model.canUploadActivities || isUploading)
                }

                if let stravaURL = activity.stravaURL {
                    Link(destination: stravaURL) {
                        actionLabel(title: "Open in Strava", systemImage: "arrow.up.right.square", tint: Color(red: 0.96, green: 0.56, blue: 0.28))
                    }
                } else if let uploadedActivityID = activity.uploadedActivityID,
                          let uploadedURL = URL(string: "https://www.strava.com/activities/\(uploadedActivityID)") {
                    Link(destination: uploadedURL) {
                        actionLabel(title: "Open Uploaded Activity", systemImage: "arrow.up.right.square", tint: Color(red: 0.96, green: 0.56, blue: 0.28))
                    }
                }
            }
        }
    }

    private var overviewSection: some View {
        detailCard(title: "Overview") {
            VStack(spacing: 12) {
                detailRow("Activity", activity.sportDisplayName)
                detailRow("Date", RouteDisplayFormatter.absoluteDate(activity.startDate))
                detailRow("Distance", RouteDisplayFormatter.distance(activity.distanceMeters))
                detailRow("Climb", RouteDisplayFormatter.climb(activity.elevationGainMeters))
                detailRow("Moving Time", RouteDisplayFormatter.duration(resolvedMovingTime))
                detailRow("Elapsed Time", RouteDisplayFormatter.duration(resolvedElapsedTime))
                detailRow("New Coverage", RouteDisplayFormatter.distance(activity.newCoverageMeters))
                detailRow("Location", activity.startAddressText ?? activity.displayLocation.nilIfEmpty ?? "Unknown")
                detailRow("Source", activity.sourceKind == .strava ? "Strava" : "Local / Imported")
                if let lastUploadStatus = activity.lastUploadStatus?.trimmed.nilIfEmpty {
                    detailRow("Upload Status", lastUploadStatus)
                }
            }
        }
    }

    private var workoutMetricsSection: some View {
        detailCard(title: "Workout Metrics") {
            ActivityDetailMetricGrid(items: workoutMetricItems)
        }
    }

    @ViewBuilder
    private var workoutAnalysisSection: some View {
        if let effortAnalysis {
            detailCard(title: "Heart Rate & Effort") {
                VStack(alignment: .leading, spacing: 12) {
                    ActivityDetailMetricGrid(items: heartRateMetricItems(for: effortAnalysis))
                    if !effortAnalysis.notes.isEmpty {
                        Divider()
                            .overlay(Color.white.opacity(0.08))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Highlights")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            ForEach(effortAnalysis.notes.prefix(4), id: \.self) { note in
                                Text("• \(note)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else if activity.sourceKind == .strava {
            detailCard(title: "Heart Rate & Effort") {
                Text("Refresh this activity to pull detailed streams from Strava and unlock workout-level effort analysis.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var terrainAndPacingSection: some View {
        if let effortAnalysis {
            detailCard(title: "Terrain & Pacing") {
                ActivityDetailMetricGrid(items: terrainMetricItems(for: effortAnalysis))
            }
        }
    }

    @ViewBuilder
    private var conditionsAndDataQualitySection: some View {
        if let effortAnalysis {
            detailCard(title: "Conditions & Data Quality") {
                VStack(alignment: .leading, spacing: 12) {
                    ActivityDetailMetricGrid(items: conditionsAndDataQualityItems(for: effortAnalysis))

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    VStack(spacing: 10) {
                        detailRow("HR Source", effortAnalysis.heartRate.sourceLabel)
                        detailRow("Speed Source", effortAnalysis.speed.sourceLabel)
                        detailRow("Grade Source", effortAnalysis.grade.sourceLabel)
                        detailRow("Movement Source", effortAnalysis.moving.sourceLabel)
                        detailRow("Temperature Source", effortAnalysis.temperature.sourceLabel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var analysisNotesSection: some View {
        if let effortAnalysis, !effortAnalysis.notes.isEmpty {
            detailCard(title: "Analysis Notes") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(effortAnalysis.notes, id: \.self) { note in
                        Text("• \(note)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var workoutMetricItems: [ActivityDetailMetricItem] {
        var items: [ActivityDetailMetricItem] = [
            ActivityDetailMetricItem(
                title: usesPacePresentation ? "Avg Pace" : "Avg Speed",
                value: averagePaceOrSpeedValue,
                caption: usesPacePresentation ? "moving-time adjusted" : "moving-time adjusted"
            ),
            ActivityDetailMetricItem(
                title: "Moving",
                value: RouteDisplayFormatter.duration(resolvedMovingTime),
                caption: "time in motion"
            ),
            ActivityDetailMetricItem(
                title: "Elapsed",
                value: RouteDisplayFormatter.duration(resolvedElapsedTime),
                caption: "including stoppage"
            ),
            ActivityDetailMetricItem(
                title: "Paused",
                value: pausedDuration > 0 ? RouteDisplayFormatter.duration(pausedDuration) : "None",
                caption: "non-moving time"
            ),
            ActivityDetailMetricItem(
                title: "Moving %",
                value: movingFractionLabel,
                caption: "motion efficiency"
            ),
            ActivityDetailMetricItem(
                title: "Vertical / Hr",
                value: verticalRateLabel,
                caption: "climb rate"
            )
        ]

        if activity.newCoverageMeters > 0 {
            items.append(
                ActivityDetailMetricItem(
                    title: "New Ground",
                    value: RouteDisplayFormatter.distance(activity.newCoverageMeters),
                    caption: "fresh explorer coverage"
                )
            )
        }

        return items
    }

    private func heartRateMetricItems(for analysis: ActivityEffortAnalysis) -> [ActivityDetailMetricItem] {
        [
            ActivityDetailMetricItem(
                title: "Avg HR",
                value: bpmLabel(analysis.heartRate.averageBpm),
                caption: "session average"
            ),
            ActivityDetailMetricItem(
                title: "Max HR",
                value: bpmLabel(analysis.heartRate.maxBpm),
                caption: "session peak"
            ),
            ActivityDetailMetricItem(
                title: "Sustained HR",
                value: bpmLabel(analysis.heartRate.sustainedMedianBpm),
                caption: "steady-work median"
            ),
            ActivityDetailMetricItem(
                title: "Working Range",
                value: heartRateRangeLabel(analysis),
                caption: "moving p10-p90"
            ),
            ActivityDetailMetricItem(
                title: "Sustained Effort",
                value: normalizedPercentLabel(analysis.derivedMetrics.sustainedEffort),
                caption: "normalized intensity"
            ),
            ActivityDetailMetricItem(
                title: "Authenticity",
                value: normalizedPercentLabel(analysis.derivedMetrics.effortAuthenticityScore),
                caption: "race-like effort score"
            )
        ]
    }

    private func terrainMetricItems(for analysis: ActivityEffortAnalysis) -> [ActivityDetailMetricItem] {
        [
            ActivityDetailMetricItem(
                title: usesPacePresentation ? "Flat Pace" : "Flat Speed",
                value: paceOrSpeedLabel(
                    speedMetersPerSecond: analysis.flatWindows.medianSpeedMetersPerSecond
                ),
                caption: "median flat segments"
            ),
            ActivityDetailMetricItem(
                title: usesPacePresentation ? "Climb Pace" : "Climb Speed",
                value: paceOrSpeedLabel(
                    speedMetersPerSecond: analysis.climbWindows.medianSpeedMetersPerSecond
                ),
                caption: "median uphill segments"
            ),
            ActivityDetailMetricItem(
                title: "Avg Grade",
                value: gradePercentLabel(analysis.grade.averagePercent),
                caption: "moving average"
            ),
            ActivityDetailMetricItem(
                title: "Max Grade",
                value: gradePercentLabel(analysis.grade.maximumPercent),
                caption: "steepest sampled"
            ),
            ActivityDetailMetricItem(
                title: "Start-Flat Pace",
                value: paceOrSpeedLabel(
                    speedMetersPerSecond: analysis.firstThirdFlatWindows.medianSpeedMetersPerSecond
                ),
                caption: "first-third flats"
            ),
            ActivityDetailMetricItem(
                title: "Finish-Flat Pace",
                value: paceOrSpeedLabel(
                    speedMetersPerSecond: analysis.lastThirdFlatWindows.medianSpeedMetersPerSecond
                ),
                caption: "last-third flats"
            ),
            ActivityDetailMetricItem(
                title: "Decoupling",
                value: normalizedPercentLabel(analysis.derivedMetrics.decoupling),
                caption: "pace fade vs HR drift"
            ),
            ActivityDetailMetricItem(
                title: "Flat Efficiency",
                value: compactDecimalLabel(analysis.derivedMetrics.flatEfficiency),
                caption: "speed per normalized HR"
            )
        ]
    }

    private func conditionsAndDataQualityItems(for analysis: ActivityEffortAnalysis) -> [ActivityDetailMetricItem] {
        [
            ActivityDetailMetricItem(
                title: "Avg Temp",
                value: temperatureLabel(analysis.temperature.averageCelsius),
                caption: "ambient conditions"
            ),
            ActivityDetailMetricItem(
                title: "Temp Range",
                value: temperatureRangeLabel(analysis),
                caption: "min to max"
            ),
            ActivityDetailMetricItem(
                title: "Heat Penalty",
                value: normalizedPercentLabel(analysis.derivedMetrics.heatPenalty),
                caption: "estimated slowdown"
            ),
            ActivityDetailMetricItem(
                title: "Coords",
                value: RouteDisplayFormatter.compactCount(analysis.coverage.coordinateSampleCount),
                caption: "location samples"
            ),
            ActivityDetailMetricItem(
                title: "Elevation",
                value: RouteDisplayFormatter.compactCount(analysis.coverage.altitudeSampleCount),
                caption: "altitude samples"
            ),
            ActivityDetailMetricItem(
                title: "HR Samples",
                value: RouteDisplayFormatter.compactCount(analysis.coverage.heartRateSampleCount),
                caption: "heart-rate samples"
            ),
            ActivityDetailMetricItem(
                title: "Speed Samples",
                value: RouteDisplayFormatter.compactCount(analysis.coverage.speedSampleCount),
                caption: "speed samples"
            ),
            ActivityDetailMetricItem(
                title: "Temp Samples",
                value: RouteDisplayFormatter.compactCount(analysis.coverage.temperatureSampleCount),
                caption: analysis.hasTemperatureFallback ? "weather fallback" : "observed stream"
            )
        ]
    }

    private var averagePaceOrSpeedValue: String {
        if usesPacePresentation {
            return RouteDisplayFormatter.pace(resolvedMovingTime, overDistanceMeters: activity.distanceMeters)
        }

        let speed = activity.averageSpeedMetersPerSecond > 0
            ? activity.averageSpeedMetersPerSecond
            : (activity.distanceMeters > 0 && resolvedMovingTime > 0 ? activity.distanceMeters / resolvedMovingTime : 0)
        return RouteDisplayFormatter.speed(speed)
    }

    private var movingFractionLabel: String {
        guard resolvedElapsedTime > 0 else {
            return "-"
        }

        return RouteDisplayFormatter.percent(resolvedMovingTime / resolvedElapsedTime)
    }

    private var verticalRateLabel: String {
        guard resolvedMovingTime > 0 else {
            return "-"
        }

        let metersPerHour = activity.elevationGainMeters / (resolvedMovingTime / 3600)
        return RouteDisplayFormatter.climb(metersPerHour)
    }

    private func bpmLabel(_ value: Double?) -> String {
        guard let value, value > 0, value.isFinite else {
            return "-"
        }

        return "\(Int(value.rounded())) bpm"
    }

    private func heartRateRangeLabel(_ analysis: ActivityEffortAnalysis) -> String {
        let low = analysis.heartRate.movingPercentiles?.p10
        let high = analysis.heartRate.movingPercentiles?.p90
        guard let low, let high, low > 0, high > 0 else {
            return "-"
        }

        return "\(Int(low.rounded()))-\(Int(high.rounded())) bpm"
    }

    private func normalizedPercentLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "-"
        }

        return RouteDisplayFormatter.percent(value)
    }

    private func gradePercentLabel(_ gradePercent: Double?) -> String {
        guard let gradePercent, gradePercent.isFinite else {
            return "-"
        }

        return RouteDisplayFormatter.percent(abs(gradePercent) / 100)
    }

    private func compactDecimalLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "-"
        }

        return String(format: "%.2f", value)
    }

    private func temperatureLabel(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else {
            return "-"
        }

        let value = RouteDisplayFormatter.measurementSystem == .metric
            ? celsius
            : (celsius * 9 / 5) + 32
        let unit = RouteDisplayFormatter.measurementSystem == .metric ? "°C" : "°F"
        return "\(Int(value.rounded()))\(unit)"
    }

    private func temperatureRangeLabel(_ analysis: ActivityEffortAnalysis) -> String {
        guard let minimum = analysis.temperature.minimumCelsius,
              let maximum = analysis.temperature.maximumCelsius else {
            return "-"
        }

        return "\(temperatureLabel(minimum))-\(temperatureLabel(maximum))"
    }

    private func paceOrSpeedLabel(speedMetersPerSecond: Double?) -> String {
        guard let speedMetersPerSecond, speedMetersPerSecond > 0, speedMetersPerSecond.isFinite else {
            return "-"
        }

        if usesPacePresentation {
            let unitDistanceMeters = RouteDisplayFormatter.measurementSystem == .metric ? 1_000.0 : 1_609.34
            let secondsPerUnit = unitDistanceMeters / speedMetersPerSecond
            return "\(RouteDisplayFormatter.raceTime(secondsPerUnit)) /\(RouteDisplayFormatter.measurementSystem.distanceUnitLabel)"
        }

        return RouteDisplayFormatter.speed(speedMetersPerSecond)
    }

    private func detailCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            content()
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(title: title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ActivityDetailMetricItem: Identifiable {
    let title: String
    let value: String
    let caption: String

    var id: String { title }
}

private struct ActivityDetailMetricGrid: View {
    let items: [ActivityDetailMetricItem]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(item.value)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(item.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

private struct ActivityRouteMapPlaceholderCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay {
                ProgressView()
                    .tint(.white.opacity(0.8))
            }
    }
}

private struct ActivityRouteMapCard: View {
    let activity: ActivityRecord
    let userInterfaceStyle: UIUserInterfaceStyle
    @State private var isMapVisible = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isMapVisible {
                    ActivityRouteMapViewRepresentable(
                        activity: activity,
                        userInterfaceStyle: userInterfaceStyle
                    )
                } else {
                    ActivityRouteMapPlaceholder(activity: activity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            if isMapVisible {
                RouteMapSettingsButton()
                    .padding(14)
            }
        }
        .task {
            guard !isMapVisible else {
                return
            }

            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                return
            }

            isMapVisible = true
        }
    }
}

private struct ActivityRouteMapPlaceholder: View {
    let activity: ActivityRecord

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.13, blue: 0.17),
                    Color(red: 0.06, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Image(systemName: activity.sportSymbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.67, blue: 0.48))

                Text("Loading route map")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(RouteDisplayFormatter.distance(activity.distanceMeters))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

private struct ActivityExplorerMapCard: View {
    let period: ActivityCoveragePeriodSnapshot
    let selectedActivity: ActivityRecord?
    let userInterfaceStyle: UIUserInterfaceStyle

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ActivityExplorerMapViewRepresentable(
                period: period,
                selectedActivity: selectedActivity,
                userInterfaceStyle: userInterfaceStyle
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(alignment: .trailing, spacing: 12) {
                RouteMapSettingsButton()

                Spacer(minLength: 0)

                ActivityExplorerLegend()
            }
            .padding(14)
        }
    }
}

private struct ActivityExplorerLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: Color(red: 1.0, green: 0.58, blue: 0.18), title: "Visited")
            legendRow(color: Color(red: 0.22, green: 0.82, blue: 1.0), title: "Cluster")
            legendRow(color: Color(red: 1.0, green: 0.84, blue: 0.28), title: "Square")
            legendRow(color: Color.white, title: "Selected")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func legendRow(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

private struct ActivityRouteMapViewRepresentable: UIViewRepresentable {
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue

    let activity: ActivityRecord
    let userInterfaceStyle: UIUserInterfaceStyle

    private var appRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private var appRouteMapPerspective: AppRouteMapPerspective {
        AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? .twoDimensional
    }

    private var resolvedMapStyle: MapStyle {
        appRouteMapStyle.resolvedStyle(colorScheme: userInterfaceStyle)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MapView {
        RouteVaultMapboxConfiguration.configure()

        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                mapStyle: resolvedMapStyle,
                cameraOptions: CameraOptions(
                    center: activity.startCoordinate,
                    zoom: 10,
                    pitch: appRouteMapPerspective.isThreeDimensional ? appRouteMapPerspective.pitch : 0
                )
            )
        )
        context.coordinator.bind(to: mapView)
        configure(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        configure(mapView)
        context.coordinator.update(
            mapView: mapView,
            activity: activity,
            routeMapStyle: appRouteMapStyle,
            routeMapPerspective: appRouteMapPerspective,
            userInterfaceStyle: userInterfaceStyle
        )
    }

    private func configure(_ mapView: MapView) {
        mapView.location.options.puckType = .puck2D()
        mapView.gestures.options.pitchEnabled = appRouteMapPerspective.isThreeDimensional
        mapView.gestures.options.rotateEnabled = true

        var ornaments = mapView.ornaments.options
        ornaments.compass.visibility = .hidden
        ornaments.scaleBar.visibility = .hidden
        mapView.ornaments.options = ornaments
    }

    final class Coordinator {
        private static let maximumDisplayPointCount = 360
        private struct ActivityRouteRenderState {
            let coordinates: [CLLocationCoordinate2D]
            let sportKind: RouteSportKind
            let perspective: AppRouteMapPerspective
            let usesStandardDarkReadabilityTuning: Bool
        }

        private weak var mapView: MapView?
        private var cancelables = Set<AnyCancelable>()
        private var routeOutlineManager: PolylineAnnotationManager?
        private var routeLineManager: PolylineAnnotationManager?
        private var markerManager: PointAnnotationManager?
        private var lastSignature: Int?
        private var lastStyleKey: String?
        private var currentUsesStandardDarkReadabilityTuning = false
        private var currentRouteRenderState: ActivityRouteRenderState?

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
                    usesStandardDarkStyle: self.currentUsesStandardDarkReadabilityTuning
                )
                RouteMapTerrainTuning.apply(
                    to: mapView.mapboxMap,
                    perspective: self.currentRouteRenderState?.perspective ?? .defaultValue
                )
                self.recreateManagers(on: mapView)
                self.reapplyCurrentState(on: mapView)
            }
            .store(in: &cancelables)
        }

        func update(
            mapView: MapView,
            activity: ActivityRecord,
            routeMapStyle: AppRouteMapStyle,
            routeMapPerspective: AppRouteMapPerspective,
            userInterfaceStyle: UIUserInterfaceStyle
        ) {
            let resolvedMapStyle: MapStyle
            let usesStandardDarkReadabilityTuning: Bool

            resolvedMapStyle = routeMapStyle.resolvedStyle(colorScheme: userInterfaceStyle)
            usesStandardDarkReadabilityTuning = routeMapStyle.usesStandardDarkReadabilityTuning(
                colorScheme: userInterfaceStyle
            )
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: routeMapPerspective
            )

            let styleKey = "\(routeMapStyle.rawValue)-activity-\(userInterfaceStyle.rawValue)-\(activity.prefersOutdoorsMapStyle)"
            currentUsesStandardDarkReadabilityTuning = usesStandardDarkReadabilityTuning

            if lastStyleKey == nil {
                lastStyleKey = styleKey
            } else if styleKey != lastStyleKey {
                lastStyleKey = styleKey
                mapView.mapboxMap.mapStyle = resolvedMapStyle
                recreateManagers(on: mapView)
                lastSignature = nil
            }

            let coordinates = activity.mapDisplayCoordinates(maximumPointCount: Self.maximumDisplayPointCount)
            currentRouteRenderState = ActivityRouteRenderState(
                coordinates: coordinates,
                sportKind: activity.sportKind,
                perspective: routeMapPerspective,
                usesStandardDarkReadabilityTuning: usesStandardDarkReadabilityTuning
            )
            var hasher = Hasher()
            hasher.combine(activity.activityKey)
            hasher.combine(activity.sportTypeRawValue)
            hasher.combine(activity.legacyTypeRawValue)
            hasher.combine(activity.syncedAt.timeIntervalSinceReferenceDate)
            hasher.combine(activity.updatedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(activity.detailIndexedAt?.timeIntervalSinceReferenceDate ?? 0)
            hasher.combine(routeMapPerspective.rawValue)
            hasher.combine(coordinates.count)
            let signature = hasher.finalize()
            guard signature != lastSignature else {
                return
            }

            ensureManagers(on: mapView)
            render(coordinates: coordinates, sportKind: activity.sportKind)
            lastSignature = signature
            fit(coordinates: coordinates, on: mapView, perspective: routeMapPerspective)
        }

        private func reapplyCurrentState(on mapView: MapView) {
            guard let currentRouteRenderState else {
                return
            }

            ensureManagers(on: mapView)
            render(
                coordinates: currentRouteRenderState.coordinates,
                sportKind: currentRouteRenderState.sportKind
            )
            fit(
                coordinates: currentRouteRenderState.coordinates,
                on: mapView,
                perspective: currentRouteRenderState.perspective
            )
            lastSignature = nil
        }

        private func recreateManagers(on mapView: MapView) {
            mapView.annotations.removeAnnotationManager(withId: "activity-route-outline")
            mapView.annotations.removeAnnotationManager(withId: "activity-route-line")
            mapView.annotations.removeAnnotationManager(withId: "activity-route-markers")
            routeOutlineManager = mapView.annotations.makePolylineAnnotationManager(id: "activity-route-outline")
            routeLineManager = mapView.annotations.makePolylineAnnotationManager(id: "activity-route-line")
            markerManager = mapView.annotations.makePointAnnotationManager(id: "activity-route-markers")
        }

        private func ensureManagers(on mapView: MapView) {
            if routeOutlineManager == nil || routeLineManager == nil || markerManager == nil {
                recreateManagers(on: mapView)
            }
        }

        private func render(coordinates: [CLLocationCoordinate2D], sportKind: RouteSportKind) {
            guard coordinates.count > 1 else {
                routeOutlineManager?.annotations = []
                routeLineManager?.annotations = []
                markerManager?.annotations = []
                return
            }

            var outline = PolylineAnnotation(lineCoordinates: coordinates)
            outline.lineColor = StyleColor(RouteMapLineStyle.outlineColor)
            outline.lineWidth = 5.6

            var line = PolylineAnnotation(lineCoordinates: coordinates)
            line.lineColor = StyleColor(RouteMapLineStyle.fillColor)
            line.lineWidth = 3.8

            routeOutlineManager?.lineDasharray = nil
            routeLineManager?.lineDasharray = activitySurfaceKind(for: sportKind) == .paved ? nil : RouteMapLineStyle.unpavedDashPattern
            routeOutlineManager?.annotations = [outline]
            routeLineManager?.annotations = [line]
            markerManager?.annotations = []
        }

        private func fit(
            coordinates: [CLLocationCoordinate2D],
            on mapView: MapView,
            perspective: AppRouteMapPerspective
        ) {
            guard coordinates.count > 1 else {
                return
            }

            do {
                let camera = try mapView.mapboxMap.camera(
                    for: coordinates,
                    camera: CameraOptions(
                        bearing: 0,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    coordinatesPadding: UIEdgeInsets(top: 52, left: 36, bottom: 52, right: 36),
                    maxZoom: 15.8,
                    offset: nil
                )
                mapView.camera.ease(to: camera, duration: 0.25)
            } catch { }
        }
    }
}

private struct ActivityExplorerMapViewRepresentable: UIViewRepresentable {
    @AppStorage(AppRouteMapStyle.storageKey) private var appRouteMapStyleRawValue = AppRouteMapStyle.defaultValue.rawValue
    @AppStorage(AppRouteMapPerspective.storageKey) private var appRouteMapPerspectiveRawValue = AppRouteMapPerspective.defaultValue.rawValue

    let period: ActivityCoveragePeriodSnapshot
    let selectedActivity: ActivityRecord?
    let userInterfaceStyle: UIUserInterfaceStyle

    private var appRouteMapStyle: AppRouteMapStyle {
        AppRouteMapStyle.resolved(from: appRouteMapStyleRawValue)
    }

    private var appRouteMapPerspective: AppRouteMapPerspective {
        AppRouteMapPerspective(rawValue: appRouteMapPerspectiveRawValue) ?? .twoDimensional
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MapView {
        RouteVaultMapboxConfiguration.configure()

        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                mapStyle: appRouteMapStyle.resolvedStyle(colorScheme: userInterfaceStyle),
                cameraOptions: CameraOptions(
                    center: selectedActivity?.startCoordinate ?? period.explorerTiles.first?.polygon.first,
                    zoom: 7,
                    pitch: appRouteMapPerspective.isThreeDimensional ? appRouteMapPerspective.pitch : 0
                )
            )
        )
        context.coordinator.bind(to: mapView)
        configure(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        configure(mapView)
        context.coordinator.update(
            mapView: mapView,
            period: period,
            selectedActivity: selectedActivity,
            routeMapStyle: appRouteMapStyle,
            routeMapPerspective: appRouteMapPerspective,
            userInterfaceStyle: userInterfaceStyle
        )
    }

    private func configure(_ mapView: MapView) {
        mapView.location.options.puckType = .puck2D()
        mapView.gestures.options.pitchEnabled = appRouteMapPerspective.isThreeDimensional
        mapView.gestures.options.rotateEnabled = true

        var ornaments = mapView.ornaments.options
        ornaments.compass.visibility = .hidden
        ornaments.scaleBar.visibility = .hidden
        mapView.ornaments.options = ornaments
    }

    final class Coordinator {
        private weak var mapView: MapView?
        private var cancelables = Set<AnyCancelable>()
        private var tileManager: PolygonAnnotationManager?
        private var selectedOutlineManager: PolylineAnnotationManager?
        private var selectedLineManager: PolylineAnnotationManager?
        private var lastSignature: Int?
        private var lastStyleKey: String?
        private var lastPerspective: AppRouteMapPerspective?
        private var currentUsesStandardDarkReadabilityTuning = false

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
                    usesStandardDarkStyle: self.currentUsesStandardDarkReadabilityTuning
                )
                RouteMapTerrainTuning.apply(
                    to: mapView.mapboxMap,
                    perspective: self.lastPerspective ?? .defaultValue
                )
                self.recreateManagers(on: mapView)
                self.lastSignature = nil
            }
            .store(in: &cancelables)
        }

        func update(
            mapView: MapView,
            period: ActivityCoveragePeriodSnapshot,
            selectedActivity: ActivityRecord?,
            routeMapStyle: AppRouteMapStyle,
            routeMapPerspective: AppRouteMapPerspective,
            userInterfaceStyle: UIUserInterfaceStyle
        ) {
            let styleKey = "\(routeMapStyle.rawValue)-\(userInterfaceStyle.rawValue)"
            currentUsesStandardDarkReadabilityTuning = routeMapStyle.usesStandardDarkReadabilityTuning(
                colorScheme: userInterfaceStyle
            )
            lastPerspective = routeMapPerspective
            RouteMapTerrainTuning.apply(
                to: mapView.mapboxMap,
                perspective: routeMapPerspective
            )
            if styleKey != lastStyleKey {
                lastStyleKey = styleKey
                mapView.mapboxMap.mapStyle = routeMapStyle.resolvedStyle(colorScheme: userInterfaceStyle)
                recreateManagers(on: mapView)
            }

            var hasher = Hasher()
            hasher.combine(period.id)
            hasher.combine(period.visitedTileCount)
            hasher.combine(period.bestSquare.sideLength)
            hasher.combine(period.bestCluster.tileCount)
            hasher.combine(tileHash(for: period.explorerTiles))
            hasher.combine(selectedActivity?.activityKey)
            hasher.combine(selectedActivity?.activityGeometryPolyline)
            hasher.combine(routeMapPerspective.rawValue)
            let signature = hasher.finalize()
            guard signature != lastSignature else {
                return
            }

            ensureManagers(on: mapView)
            render(period: period, selectedActivity: selectedActivity)
            lastSignature = signature
            fit(period: period, selectedActivity: selectedActivity, on: mapView, perspective: routeMapPerspective)
        }

        private func recreateManagers(on mapView: MapView) {
            mapView.annotations.removeAnnotationManager(withId: "activity-explorer-tiles")
            mapView.annotations.removeAnnotationManager(withId: "activity-selected-outline")
            mapView.annotations.removeAnnotationManager(withId: "activity-selected-line")
            tileManager = mapView.annotations.makePolygonAnnotationManager(id: "activity-explorer-tiles")
            selectedOutlineManager = mapView.annotations.makePolylineAnnotationManager(id: "activity-selected-outline")
            selectedLineManager = mapView.annotations.makePolylineAnnotationManager(id: "activity-selected-line")
        }

        private func ensureManagers(on mapView: MapView) {
            if tileManager == nil || selectedOutlineManager == nil || selectedLineManager == nil {
                recreateManagers(on: mapView)
            }
        }

        private func render(period: ActivityCoveragePeriodSnapshot, selectedActivity: ActivityRecord?) {
            let squareTiles = Set(period.bestSquare.tiles)
            let clusterTiles = Set(period.bestCluster.tiles)
            tileManager?.annotations = period.explorerTiles.map { tile in
                var polygon = PolygonAnnotation(
                    id: tile.id,
                    polygon: Polygon(outerRing: Ring(coordinates: tile.polygon))
                )
                let isSquare = squareTiles.contains(tile.coordinate)
                let isCluster = clusterTiles.contains(tile.coordinate)
                let visitAlpha = min(0.22 + (Double(min(tile.visitCount, 5)) * 0.06), 0.48)

                polygon.fillColor = StyleColor(
                    isSquare
                        ? UIColor(red: 1.0, green: 0.84, blue: 0.28, alpha: 1.0)
                        : (isCluster
                            ? UIColor(red: 0.22, green: 0.82, blue: 1.0, alpha: 1.0)
                            : UIColor(red: 1.0, green: 0.58, blue: 0.18, alpha: 1.0))
                )
                polygon.fillOpacity = isSquare ? 0.52 : (isCluster ? 0.40 : visitAlpha)
                polygon.fillOutlineColor = StyleColor(
                    isSquare
                        ? UIColor(red: 1.0, green: 0.95, blue: 0.72, alpha: 0.98)
                        : UIColor.white.withAlphaComponent(isCluster ? 0.34 : 0.12)
                )
                return polygon
            }

            guard let selectedActivity, selectedActivity.coordinates.count > 1 else {
                selectedOutlineManager?.annotations = []
                selectedLineManager?.annotations = []
                return
            }

            var outline = PolylineAnnotation(lineCoordinates: selectedActivity.coordinates)
            outline.lineColor = StyleColor(RouteMapLineStyle.outlineColor)
            outline.lineWidth = RouteMapLineStyle.outlineWidth

            var line = PolylineAnnotation(lineCoordinates: selectedActivity.coordinates)
            line.lineColor = StyleColor(RouteMapLineStyle.fillColor)
            line.lineWidth = RouteMapLineStyle.fillWidth

            selectedOutlineManager?.annotations = [outline]
            selectedOutlineManager?.lineDasharray = nil
            selectedLineManager?.annotations = [line]
            selectedLineManager?.lineDasharray = activitySurfaceKind(for: selectedActivity.sportKind) == .paved ? nil : RouteMapLineStyle.unpavedDashPattern
        }

        private func fit(
            period: ActivityCoveragePeriodSnapshot,
            selectedActivity: ActivityRecord?,
            on mapView: MapView,
            perspective: AppRouteMapPerspective
        ) {
            let coordinates: [CLLocationCoordinate2D]
            if let selectedActivity, selectedActivity.coordinates.count > 1 {
                coordinates = selectedActivity.coordinates
            } else {
                coordinates = period.explorerTiles.flatMap(\.polygon)
            }

            guard coordinates.count > 1 else {
                return
            }

            do {
                let camera = try mapView.mapboxMap.camera(
                    for: coordinates,
                    camera: CameraOptions(
                        bearing: 0,
                        pitch: perspective.isThreeDimensional ? perspective.pitch : 0
                    ),
                    coordinatesPadding: UIEdgeInsets(top: 34, left: 28, bottom: 34, right: 28),
                    maxZoom: selectedActivity == nil ? 12.6 : 15.8,
                    offset: nil
                )
                mapView.camera.ease(to: camera, duration: 0.25)
            } catch { }
        }

        private func tileHash(for tiles: [ActivityExplorerTile]) -> Int {
            var hasher = Hasher()
            hasher.combine(tiles.count)
            for tile in tiles.prefix(4_000) {
                hasher.combine(tile.coordinate)
                hasher.combine(tile.visitCount)
            }
            return hasher.finalize()
        }
    }
}

private extension UTType {
    static var gpxActivity: UTType {
        UTType(filenameExtension: "gpx") ?? .xml
    }
}

private func activitySurfaceKind(for sportKind: RouteSportKind) -> RouteSurfaceKind? {
    switch sportKind {
    case .ride:
        return .paved
    case .mountainBike, .trailRun, .hike, .snowshoe, .ski:
        return .trail
    case .mixedRide, .gravelRide, .cyclocross:
        return .mixed
    case .run, .walk, .wheelchair, .other:
        return nil
    }
}
